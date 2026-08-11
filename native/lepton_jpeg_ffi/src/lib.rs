use std::ffi::{CStr, c_char};
use std::fs::File;
use std::io::{BufRead, BufReader, BufWriter, Read, Seek, SeekFrom, Write};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Instant;

use lepton_jpeg::{
    DEFAULT_THREAD_POOL, EnabledFeatures, StreamPosition, decode_lepton, encode_lepton,
};

const STATUS_OK: i32 = 0;
const STATUS_INVALID_ARGUMENT: i32 = 1;
const STATUS_FILE_IO_FAILED: i32 = 2;
const STATUS_CODEC_FAILED: i32 = 3;
const STATUS_PANIC: i32 = 4;
const STATUS_CANCELLED: i32 = 5;

static CANCELLATION_GENERATION: AtomicU64 = AtomicU64::new(0);

static VERSION: &[u8] = b"0.5.8\0";
static REVISION: &[u8] = b"90fdc27828676892fbb41777cfcc6bad1e470516\0";
static ERROR_OK: &[u8] = b"ok\0";
static ERROR_INVALID_ARGUMENT: &[u8] = b"invalid argument\0";
static ERROR_FILE_IO_FAILED: &[u8] = b"file I/O failed\0";
static ERROR_CODEC_FAILED: &[u8] = b"Lepton codec failed\0";
static ERROR_PANIC: &[u8] = b"Lepton wrapper panic\0";
static ERROR_CANCELLED: &[u8] = b"Lepton operation cancelled\0";
static ERROR_UNKNOWN: &[u8] = b"unknown Lepton status\0";

#[derive(Clone, Copy)]
struct CancellationGuard {
    expected_generation: Option<u64>,
}

impl CancellationGuard {
    fn none() -> Self {
        Self {
            expected_generation: None,
        }
    }

    fn expecting(generation: u64) -> Self {
        Self {
            expected_generation: Some(generation),
        }
    }

    fn is_cancelled(self) -> bool {
        self.expected_generation
            .is_some_and(|expected| CANCELLATION_GENERATION.load(Ordering::Acquire) != expected)
    }

    fn check_io(self) -> std::io::Result<()> {
        if self.is_cancelled() {
            Err(std::io::Error::new(
                std::io::ErrorKind::Interrupted,
                "Lepton operation cancelled",
            ))
        } else {
            Ok(())
        }
    }
}

struct CancellationReader<R> {
    reader: R,
    guard: CancellationGuard,
}

impl<R> CancellationReader<R> {
    fn new(reader: R, guard: CancellationGuard) -> Self {
        Self { reader, guard }
    }
}

impl<R: Read> Read for CancellationReader<R> {
    fn read(&mut self, buffer: &mut [u8]) -> std::io::Result<usize> {
        self.guard.check_io()?;
        self.reader.read(buffer)
    }
}

impl<R: BufRead> BufRead for CancellationReader<R> {
    fn fill_buf(&mut self) -> std::io::Result<&[u8]> {
        self.guard.check_io()?;
        self.reader.fill_buf()
    }

    fn consume(&mut self, amount: usize) {
        self.reader.consume(amount);
    }
}

impl<R: Seek> Seek for CancellationReader<R> {
    fn seek(&mut self, position: SeekFrom) -> std::io::Result<u64> {
        self.guard.check_io()?;
        self.reader.seek(position)
    }
}

struct PositionWriter<W: Write> {
    writer: W,
    position: u64,
    guard: CancellationGuard,
}

impl<W: Write> PositionWriter<W> {
    fn new(writer: W, guard: CancellationGuard) -> Self {
        Self {
            writer,
            position: 0,
            guard,
        }
    }
}

impl<W: Write> Write for PositionWriter<W> {
    fn write(&mut self, buffer: &[u8]) -> std::io::Result<usize> {
        self.guard.check_io()?;
        let written = self.writer.write(buffer)?;
        self.position += written as u64;
        Ok(written)
    }

    fn flush(&mut self) -> std::io::Result<()> {
        self.guard.check_io()?;
        self.writer.flush()
    }
}

impl<W: Write> StreamPosition for PositionWriter<W> {
    fn position(&mut self) -> u64 {
        self.position
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn pw_lepton_version() -> *const c_char {
    VERSION.as_ptr().cast()
}

#[unsafe(no_mangle)]
pub extern "C" fn pw_lepton_revision() -> *const c_char {
    REVISION.as_ptr().cast()
}

#[unsafe(no_mangle)]
pub extern "C" fn pw_lepton_error_message(status: i32) -> *const c_char {
    match status {
        STATUS_OK => ERROR_OK,
        STATUS_INVALID_ARGUMENT => ERROR_INVALID_ARGUMENT,
        STATUS_FILE_IO_FAILED => ERROR_FILE_IO_FAILED,
        STATUS_CODEC_FAILED => ERROR_CODEC_FAILED,
        STATUS_PANIC => ERROR_PANIC,
        STATUS_CANCELLED => ERROR_CANCELLED,
        _ => ERROR_UNKNOWN,
    }
    .as_ptr()
    .cast()
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn pw_lepton_encode_jpeg_file(
    jpeg_path: *const c_char,
    lepton_path: *const c_char,
    elapsed_microseconds: *mut u64,
) -> i32 {
    unsafe {
        run_file_operation(
            jpeg_path,
            lepton_path,
            elapsed_microseconds,
            CancellationGuard::none(),
            encode_file,
        )
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn pw_lepton_reconstruct_jpeg_file(
    lepton_path: *const c_char,
    jpeg_path: *const c_char,
    elapsed_microseconds: *mut u64,
) -> i32 {
    unsafe {
        run_file_operation(
            lepton_path,
            jpeg_path,
            elapsed_microseconds,
            CancellationGuard::none(),
            decode_file,
        )
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn pw_lepton_cancellation_generation() -> u64 {
    CANCELLATION_GENERATION.load(Ordering::Acquire)
}

#[unsafe(no_mangle)]
pub extern "C" fn pw_lepton_request_cancel() {
    CANCELLATION_GENERATION.fetch_add(1, Ordering::AcqRel);
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn pw_lepton_encode_jpeg_file_cancellable(
    jpeg_path: *const c_char,
    lepton_path: *const c_char,
    expected_generation: u64,
    elapsed_microseconds: *mut u64,
) -> i32 {
    unsafe {
        run_file_operation(
            jpeg_path,
            lepton_path,
            elapsed_microseconds,
            CancellationGuard::expecting(expected_generation),
            encode_file,
        )
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn pw_lepton_reconstruct_jpeg_file_cancellable(
    lepton_path: *const c_char,
    jpeg_path: *const c_char,
    expected_generation: u64,
    elapsed_microseconds: *mut u64,
) -> i32 {
    unsafe {
        run_file_operation(
            lepton_path,
            jpeg_path,
            elapsed_microseconds,
            CancellationGuard::expecting(expected_generation),
            decode_file,
        )
    }
}

unsafe fn run_file_operation(
    source_path: *const c_char,
    destination_path: *const c_char,
    elapsed_microseconds: *mut u64,
    guard: CancellationGuard,
    operation: fn(&Path, &Path, CancellationGuard) -> Result<(), OperationError>,
) -> i32 {
    if source_path.is_null() || destination_path.is_null() {
        return STATUS_INVALID_ARGUMENT;
    }
    if !elapsed_microseconds.is_null() {
        unsafe { *elapsed_microseconds = 0 };
    }

    let source = match unsafe { c_path(source_path) } {
        Some(value) => value,
        None => return STATUS_INVALID_ARGUMENT,
    };
    let destination = match unsafe { c_path(destination_path) } {
        Some(value) => value,
        None => return STATUS_INVALID_ARGUMENT,
    };
    if guard.is_cancelled() {
        return STATUS_CANCELLED;
    }
    let started = Instant::now();
    let result = catch_unwind(AssertUnwindSafe(|| operation(&source, &destination, guard)));
    if !elapsed_microseconds.is_null() {
        let elapsed = started.elapsed().as_micros();
        unsafe { *elapsed_microseconds = elapsed.min(u64::MAX as u128) as u64 };
    }
    let status = match result {
        Ok(Ok(())) => STATUS_OK,
        Ok(Err(OperationError::Io)) => STATUS_FILE_IO_FAILED,
        Ok(Err(OperationError::Codec)) => STATUS_CODEC_FAILED,
        Err(_) => STATUS_PANIC,
    };
    if guard.is_cancelled() {
        let _ = std::fs::remove_file(&destination);
        STATUS_CANCELLED
    } else {
        status
    }
}

unsafe fn c_path(value: *const c_char) -> Option<PathBuf> {
    let bytes = unsafe { CStr::from_ptr(value) }.to_bytes();
    if bytes.is_empty() {
        return None;
    }
    let text = std::str::from_utf8(bytes).ok()?;
    Some(PathBuf::from(text))
}

#[derive(Debug)]
enum OperationError {
    Io,
    Codec,
}

fn encode_file(
    source: &Path,
    destination: &Path,
    guard: CancellationGuard,
) -> Result<(), OperationError> {
    let input = File::open(source).map_err(|_| OperationError::Io)?;
    let output = File::create(destination).map_err(|_| OperationError::Io)?;
    let mut reader = CancellationReader::new(BufReader::new(input), guard);
    let mut writer = PositionWriter::new(BufWriter::new(output), guard);
    let features = EnabledFeatures::compat_lepton_vector_write();
    encode_lepton(&mut reader, &mut writer, &features, &DEFAULT_THREAD_POOL)
        .map_err(|_| OperationError::Codec)?;
    writer.flush().map_err(|_| OperationError::Io)
}

fn decode_file(
    source: &Path,
    destination: &Path,
    guard: CancellationGuard,
) -> Result<(), OperationError> {
    let input = File::open(source).map_err(|_| OperationError::Io)?;
    let output = File::create(destination).map_err(|_| OperationError::Io)?;
    let mut reader = CancellationReader::new(BufReader::new(input), guard);
    let mut writer = PositionWriter::new(BufWriter::new(output), guard);
    let features = EnabledFeatures::compat_lepton_vector_read();
    decode_lepton(&mut reader, &mut writer, &features, &DEFAULT_THREAD_POOL)
        .map_err(|_| OperationError::Codec)?;
    writer.flush().map_err(|_| OperationError::Io)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rejects_null_paths_without_touching_outputs() {
        let status = unsafe {
            pw_lepton_encode_jpeg_file(std::ptr::null(), std::ptr::null(), std::ptr::null_mut())
        };
        assert_eq!(status, STATUS_INVALID_ARGUMENT);
    }

    #[test]
    fn stale_generation_is_cancelled_before_file_io() {
        use std::ffi::CString;

        let generation = pw_lepton_cancellation_generation();
        pw_lepton_request_cancel();
        let source = CString::new("/does/not/exist.jpg").unwrap();
        let destination = CString::new("/does/not/exist.lep").unwrap();
        let status = unsafe {
            pw_lepton_encode_jpeg_file_cancellable(
                source.as_ptr(),
                destination.as_ptr(),
                generation,
                std::ptr::null_mut(),
            )
        };

        assert_eq!(status, STATUS_CANCELLED);
    }

    #[test]
    fn frozen_jpeg_roundtrip_is_byte_exact_when_registered() {
        let Some(source) = std::env::var_os("PW_LEPTON_SMOKE_JPEG") else {
            return;
        };
        let source = PathBuf::from(source);
        let temporary_root = std::env::temp_dir();
        let suffix = std::process::id();
        let archive = temporary_root.join(format!("pw-lepton-smoke-{suffix}.lep"));
        let restored = temporary_root.join(format!("pw-lepton-smoke-{suffix}.jpg"));

        encode_file(&source, &archive, CancellationGuard::none())
            .expect("official Lepton encode must succeed");
        decode_file(&archive, &restored, CancellationGuard::none())
            .expect("official Lepton decode must succeed");
        assert_eq!(
            std::fs::read(&source).expect("source JPEG must be readable"),
            std::fs::read(&restored).expect("restored JPEG must be readable")
        );

        std::fs::remove_file(archive).expect("temporary Lepton archive must be removable");
        std::fs::remove_file(restored).expect("temporary restored JPEG must be removable");
    }
}
