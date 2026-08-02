use dsi_bitstream::dispatch::Codes;
use dsi_bitstream::prelude::BE;
use dsi_progress_logger::no_logging;
use std::collections::{BTreeMap, BTreeSet};
use std::convert::TryInto;
use std::env;
use std::fs;
use std::path::{Path, PathBuf};
use webgraph::graphs::vec_graph::VecGraph;
use webgraph::prelude::{store_ef_with_data, BvComp, BvGraph, CompFlags, LoadMem};
use webgraph::traits::{RandomAccessGraph, SequentialLabeling};

const INPUT_MAGIC: &[u8; 8] = b"PWGI1\0\0\0";
const MAPPING_MAGIC: &[u8; 8] = b"PWGM1\0\0\0";
const INPUT_HEADER_BYTES: usize = 52;
const INPUT_RECORD_BYTES: usize = 32;
const MAX_IMAGE_ID: u64 = 2_147_483_647;
const REVISION: &str = "f8698a7bdda2c4e171017548307179cd5c7a3166";

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct Record {
    table: u8,
    pair_id: u64,
    row_ordinal: u32,
    source_image: u32,
    source_feature: u32,
    target_image: u32,
    target_feature: u32,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct Group {
    table: u8,
    pair_id: u64,
    row_count: u64,
}

fn read_u32(bytes: &[u8], offset: usize) -> Result<u32, String> {
    let value = bytes
        .get(offset..offset + 4)
        .ok_or_else(|| "truncated u32".to_string())?;
    Ok(u32::from_le_bytes(value.try_into().unwrap()))
}

fn read_u64(bytes: &[u8], offset: usize) -> Result<u64, String> {
    let value = bytes
        .get(offset..offset + 8)
        .ok_or_else(|| "truncated u64".to_string())?;
    Ok(u64::from_le_bytes(value.try_into().unwrap()))
}

fn append_u32(output: &mut Vec<u8>, value: u32) {
    output.extend_from_slice(&value.to_le_bytes());
}

fn append_u64(output: &mut Vec<u8>, value: u64) {
    output.extend_from_slice(&value.to_le_bytes());
}

fn append_varint(output: &mut Vec<u8>, mut value: u64) {
    loop {
        let mut byte = (value & 0x7f) as u8;
        value >>= 7;
        if value != 0 {
            byte |= 0x80;
        }
        output.push(byte);
        if value == 0 {
            break;
        }
    }
}

fn read_varint(input: &[u8], position: &mut usize) -> Result<u64, String> {
    let mut value = 0_u64;
    for shift in (0..=63).step_by(7) {
        let byte = *input
            .get(*position)
            .ok_or_else(|| "truncated varint".to_string())?;
        *position += 1;
        value |= u64::from(byte & 0x7f) << shift;
        if byte & 0x80 == 0 {
            return Ok(value);
        }
    }
    Err("oversized varint".to_string())
}

fn parse_input(bytes: &[u8]) -> Result<(Vec<Record>, [u8; 32]), String> {
    if bytes.len() < INPUT_HEADER_BYTES || &bytes[..8] != INPUT_MAGIC {
        return Err("invalid canonical graph header".to_string());
    }
    if read_u32(bytes, 8)? as usize != INPUT_RECORD_BYTES {
        return Err("unexpected canonical record size".to_string());
    }
    let record_count = usize::try_from(read_u64(bytes, 12)?)
        .map_err(|_| "record count exceeds usize".to_string())?;
    if bytes.len() != INPUT_HEADER_BYTES + record_count * INPUT_RECORD_BYTES {
        return Err("canonical graph length mismatch".to_string());
    }
    let source_body_sha: [u8; 32] = bytes[20..52].try_into().unwrap();
    let mut records = Vec::with_capacity(record_count);
    for index in 0..record_count {
        let offset = INPUT_HEADER_BYTES + index * INPUT_RECORD_BYTES;
        let table = bytes[offset];
        if table > 1 || bytes[offset + 1..offset + 4] != [0, 0, 0] {
            return Err("invalid table or reserved bytes".to_string());
        }
        records.push(Record {
            table,
            pair_id: read_u64(bytes, offset + 4)?,
            row_ordinal: read_u32(bytes, offset + 12)?,
            source_image: read_u32(bytes, offset + 16)?,
            source_feature: read_u32(bytes, offset + 20)?,
            target_image: read_u32(bytes, offset + 24)?,
            target_feature: read_u32(bytes, offset + 28)?,
        });
    }
    Ok((records, source_body_sha))
}

fn groups_from_records(records: &[Record]) -> Result<Vec<Group>, String> {
    let mut groups: Vec<Group> = Vec::new();
    for record in records {
        if record.pair_id / MAX_IMAGE_ID != u64::from(record.source_image)
            || record.pair_id % MAX_IMAGE_ID != u64::from(record.target_image)
            || record.source_image >= record.target_image
        {
            return Err("COLMAP pair identity is inconsistent".to_string());
        }
        if let Some(group) = groups.last_mut() {
            if group.table == record.table && group.pair_id == record.pair_id {
                if u64::from(record.row_ordinal) != group.row_count {
                    return Err("row ordinals are not contiguous".to_string());
                }
                group.row_count += 1;
                continue;
            }
        }
        if record.row_ordinal != 0 {
            return Err("new group does not start at row zero".to_string());
        }
        groups.push(Group {
            table: record.table,
            pair_id: record.pair_id,
            row_count: 1,
        });
    }
    Ok(groups)
}

fn encode_mapping(
    features: &[(u32, u32)],
    groups: &[Group],
    source_body_sha: &[u8; 32],
    record_count: usize,
) -> Vec<u8> {
    let mut output = Vec::new();
    output.extend_from_slice(MAPPING_MAGIC);
    append_u64(&mut output, record_count as u64);
    append_u64(&mut output, features.len() as u64);
    append_u32(&mut output, groups.len() as u32);
    output.extend_from_slice(source_body_sha);
    let mut previous_image = 0_u32;
    let mut previous_feature = 0_u32;
    for &(image, feature) in features {
        let image_delta = image - previous_image;
        append_varint(&mut output, u64::from(image_delta));
        if image_delta == 0 {
            append_varint(&mut output, u64::from(feature - previous_feature));
        } else {
            append_varint(&mut output, u64::from(feature));
        }
        previous_image = image;
        previous_feature = feature;
    }
    let mut previous_pair = [0_u64; 2];
    for group in groups {
        output.push(group.table);
        append_varint(
            &mut output,
            group.pair_id - previous_pair[group.table as usize],
        );
        append_varint(&mut output, group.row_count);
        previous_pair[group.table as usize] = group.pair_id;
    }
    output
}

fn decode_mapping(bytes: &[u8]) -> Result<(Vec<(u32, u32)>, Vec<Group>, [u8; 32]), String> {
    if bytes.len() < 60 || &bytes[..8] != MAPPING_MAGIC {
        return Err("invalid mapping header".to_string());
    }
    let record_count = read_u64(bytes, 8)?;
    let feature_count = usize::try_from(read_u64(bytes, 16)?)
        .map_err(|_| "feature count exceeds usize".to_string())?;
    let group_count = read_u32(bytes, 24)? as usize;
    let source_body_sha: [u8; 32] = bytes[28..60].try_into().unwrap();
    let mut position = 60;
    let mut features = Vec::with_capacity(feature_count);
    let mut previous_image = 0_u32;
    let mut previous_feature = 0_u32;
    for _ in 0..feature_count {
        let image_delta = u32::try_from(read_varint(bytes, &mut position)?)
            .map_err(|_| "image delta exceeds u32".to_string())?;
        let feature_value = u32::try_from(read_varint(bytes, &mut position)?)
            .map_err(|_| "feature delta exceeds u32".to_string())?;
        let image = previous_image
            .checked_add(image_delta)
            .ok_or_else(|| "image delta overflow".to_string())?;
        let feature = if image_delta == 0 {
            previous_feature
                .checked_add(feature_value)
                .ok_or_else(|| "feature delta overflow".to_string())?
        } else {
            feature_value
        };
        if let Some(previous) = features.last() {
            if *previous >= (image, feature) {
                return Err("feature mapping is not strictly sorted".to_string());
            }
        }
        features.push((image, feature));
        previous_image = image;
        previous_feature = feature;
    }
    let mut previous_pair = [0_u64; 2];
    let mut groups = Vec::with_capacity(group_count);
    let mut decoded_record_count = 0_u64;
    for _ in 0..group_count {
        let table = *bytes
            .get(position)
            .ok_or_else(|| "truncated group table".to_string())?;
        position += 1;
        if table > 1 {
            return Err("invalid group table".to_string());
        }
        let pair_id = previous_pair[table as usize]
            .checked_add(read_varint(bytes, &mut position)?)
            .ok_or_else(|| "pair delta overflow".to_string())?;
        let row_count = read_varint(bytes, &mut position)?;
        if row_count == 0 {
            return Err("empty mapping group".to_string());
        }
        groups.push(Group {
            table,
            pair_id,
            row_count,
        });
        previous_pair[table as usize] = pair_id;
        decoded_record_count += row_count;
    }
    if position != bytes.len() || decoded_record_count != record_count {
        return Err("mapping length or record count mismatch".to_string());
    }
    Ok((features, groups, source_body_sha))
}

fn canonical_bytes(records: &[Record], source_body_sha: &[u8; 32]) -> Vec<u8> {
    let mut output = Vec::with_capacity(INPUT_HEADER_BYTES + records.len() * INPUT_RECORD_BYTES);
    output.extend_from_slice(INPUT_MAGIC);
    append_u32(&mut output, INPUT_RECORD_BYTES as u32);
    append_u64(&mut output, records.len() as u64);
    output.extend_from_slice(source_body_sha);
    for record in records {
        output.push(record.table);
        output.extend_from_slice(&[0, 0, 0]);
        append_u64(&mut output, record.pair_id);
        append_u32(&mut output, record.row_ordinal);
        append_u32(&mut output, record.source_image);
        append_u32(&mut output, record.source_feature);
        append_u32(&mut output, record.target_image);
        append_u32(&mut output, record.target_feature);
    }
    output
}

fn file_size(path: &Path) -> Result<u64, String> {
    Ok(fs::metadata(path)
        .map_err(|error| format!("metadata {}: {error}", path.display()))?
        .len())
}

fn code_from_name(name: &str) -> Result<Codes, String> {
    match name {
        "gamma" => Ok(Codes::Gamma),
        "zeta3" => Ok(Codes::Zeta(3)),
        _ => Err(format!("unsupported code {name}")),
    }
}

fn run() -> Result<(), String> {
    let arguments: Vec<String> = env::args().collect();
    if arguments.len() != 7 {
        return Err("usage: worldpack_webgraph_adapter INPUT OUTPUT_DIR WINDOW MAX_REF MIN_INTERVAL gamma|zeta3".to_string());
    }
    let input_path = PathBuf::from(&arguments[1]);
    let output_dir = PathBuf::from(&arguments[2]);
    let compression_window: usize = arguments[3]
        .parse()
        .map_err(|_| "invalid compression window".to_string())?;
    let max_ref_count: usize = arguments[4]
        .parse()
        .map_err(|_| "invalid max reference count".to_string())?;
    let min_interval_length: usize = arguments[5]
        .parse()
        .map_err(|_| "invalid minimum interval length".to_string())?;
    let code_name = arguments[6].as_str();
    let code = code_from_name(code_name)?;
    if output_dir.exists() {
        return Err("output directory already exists".to_string());
    }
    fs::create_dir_all(&output_dir).map_err(|error| format!("create output: {error}"))?;

    let input = fs::read(&input_path).map_err(|error| format!("read input: {error}"))?;
    let (records, source_body_sha) = parse_input(&input)?;
    let groups = groups_from_records(&records)?;
    let mut feature_set = BTreeSet::new();
    for record in &records {
        feature_set.insert((record.source_image, record.source_feature));
        feature_set.insert((record.target_image, record.target_feature));
    }
    let features: Vec<(u32, u32)> = feature_set.into_iter().collect();
    let feature_ids: BTreeMap<(u32, u32), usize> = features
        .iter()
        .copied()
        .enumerate()
        .map(|(index, value)| (value, index))
        .collect();
    let mut graph_arcs = Vec::with_capacity(records.len() * 2);
    for (record_index, record) in records.iter().enumerate() {
        let record_node = features.len() + record_index;
        let source = feature_ids[&(record.source_image, record.source_feature)];
        let target = feature_ids[&(record.target_image, record.target_feature)];
        if source >= target {
            return Err("feature mapping does not preserve COLMAP direction".to_string());
        }
        graph_arcs.push((record_node, source));
        graph_arcs.push((record_node, target));
    }
    let graph = VecGraph::from_arcs(graph_arcs);
    let basename = output_dir.join("worldpack");
    let flags = CompFlags {
        outdegrees: code,
        references: code,
        blocks: code,
        intervals: code,
        residuals: code,
        min_interval_length,
        compression_window,
        max_ref_count,
    };
    BvComp::with_basename(&basename)
        .comp_flags(flags)
        .comp_graph::<BE>(&graph)
        .map_err(|error| format!("official WebGraph compression: {error:#}"))?;
    store_ef_with_data(
        graph.num_nodes(),
        basename.with_extension("graph"),
        basename.with_extension("offsets"),
        basename.with_extension("ef"),
        &mut no_logging![],
    )
    .map_err(|error| format!("official Elias-Fano build: {error:#}"))?;
    fs::remove_file(basename.with_extension("offsets"))
        .map_err(|error| format!("remove build-only offsets: {error}"))?;

    let mapping = encode_mapping(&features, &groups, &source_body_sha, records.len());
    let mapping_path = output_dir.join("mapping.raw");
    fs::write(&mapping_path, &mapping).map_err(|error| format!("write mapping: {error}"))?;
    let (decoded_features, decoded_groups, decoded_source_sha) = decode_mapping(&mapping)?;
    if decoded_features != features || decoded_groups != groups || decoded_source_sha != source_body_sha {
        return Err("mapping round trip mismatch".to_string());
    }

    let loaded = BvGraph::with_basename(&basename)
        .endianness::<BE>()
        .mode::<LoadMem>()
        .load()
        .map_err(|error| format!("random-access load without offsets: {error:#}"))?;
    if loaded.num_nodes() != features.len() + records.len() {
        return Err("loaded graph node count mismatch".to_string());
    }
    let mut random_read_indices = BTreeSet::new();
    for numerator in 0..8 {
        random_read_indices.insert(numerator * (records.len() - 1) / 7);
    }
    for &record_index in &random_read_indices {
        let record_node = features.len() + record_index;
        let successors: Vec<usize> = loaded.successors(record_node).collect();
        if successors.len() != 2
            || decoded_features[successors[0]]
                != (records[record_index].source_image, records[record_index].source_feature)
            || decoded_features[successors[1]]
                != (records[record_index].target_image, records[record_index].target_feature)
        {
            return Err("random-access record mismatch".to_string());
        }
    }

    let mut restored_records = Vec::with_capacity(records.len());
    let mut record_index = 0_usize;
    for group in &decoded_groups {
        let source_image = u32::try_from(group.pair_id / MAX_IMAGE_ID)
            .map_err(|_| "source image exceeds u32".to_string())?;
        let target_image = u32::try_from(group.pair_id % MAX_IMAGE_ID)
            .map_err(|_| "target image exceeds u32".to_string())?;
        for row_ordinal in 0..group.row_count {
            let record_node = decoded_features.len() + record_index;
            let successors: Vec<usize> = loaded.successors(record_node).collect();
            if successors.len() != 2 {
                return Err("record node does not have exactly two successors".to_string());
            }
            let source = decoded_features
                .get(successors[0])
                .ok_or_else(|| "source feature ID is outside mapping".to_string())?;
            let target = decoded_features
                .get(successors[1])
                .ok_or_else(|| "target feature ID is outside mapping".to_string())?;
            if source.0 != source_image || target.0 != target_image {
                return Err("successor images do not match pair identity".to_string());
            }
            restored_records.push(Record {
                table: group.table,
                pair_id: group.pair_id,
                row_ordinal: u32::try_from(row_ordinal)
                    .map_err(|_| "row ordinal exceeds u32".to_string())?,
                source_image,
                source_feature: source.1,
                target_image,
                target_feature: target.1,
            });
            record_index += 1;
        }
    }
    let restored = canonical_bytes(&restored_records, &decoded_source_sha);
    if restored != input {
        return Err("complete canonical graph restoration mismatch".to_string());
    }
    let restored_path = output_dir.join("restored.bin");
    fs::write(&restored_path, &restored).map_err(|error| format!("write restored: {error}"))?;

    let graph_bytes = file_size(&basename.with_extension("graph"))?;
    let properties_bytes = file_size(&basename.with_extension("properties"))?;
    let elias_fano_bytes = file_size(&basename.with_extension("ef"))?;
    let mapping_raw_bytes = file_size(&mapping_path)?;
    println!(
        "{{\"revision\":\"{}\",\"records\":{},\"feature_nodes\":{},\"record_nodes\":{},\"graph_arcs\":{},\"graph_bytes\":{},\"properties_bytes\":{},\"elias_fano_bytes\":{},\"mapping_raw_bytes\":{},\"offsets_persisted_bytes\":0,\"random_reads\":{},\"byte_equal\":1}}",
        REVISION,
        records.len(),
        features.len(),
        records.len(),
        records.len() * 2,
        graph_bytes,
        properties_bytes,
        elias_fano_bytes,
        mapping_raw_bytes,
        random_read_indices.len(),
    );
    Ok(())
}

fn main() {
    if let Err(error) = run() {
        eprintln!("worldpack_webgraph_adapter: {error}");
        std::process::exit(1);
    }
}
