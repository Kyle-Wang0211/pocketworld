#include "pwa2_official_codec_backend.h"

#include <CommonCrypto/CommonDigest.h>

#include <array>
#include <limits>
#include <memory>
#include <sstream>

#include "blosc2.h"
#include "cpcodec.h"
#include "openzl/zl_compress.h"
#include "openzl/zl_compressor.h"
#include "openzl/zl_decompress.h"
#include "openzl/zl_errors.h"
#include "openzl/zl_public_nodes.h"
#include "openzl/zl_selector.h"

namespace pw::codecbench {
namespace {

constexpr int kOpenZlFormatVersion = 16;
constexpr int kOpenZlDefaultLevel = 6;

using CompressorPtr =
    std::unique_ptr<ZL_Compressor, decltype(&ZL_Compressor_free)>;
using CompressionContextPtr = std::unique_ptr<ZL_CCtx, decltype(&ZL_CCtx_free)>;
using DecompressionContextPtr =
    std::unique_ptr<ZL_DCtx, decltype(&ZL_DCtx_free)>;
using TypedRefPtr = std::unique_ptr<ZL_TypedRef, decltype(&ZL_TypedRef_free)>;
using TypedBufferPtr =
    std::unique_ptr<ZL_TypedBuffer, decltype(&ZL_TypedBuffer_free)>;
using BloscContextPtr =
    std::unique_ptr<blosc2_context, decltype(&blosc2_free_ctx)>;

std::array<std::uint8_t, 32> Sha256(
    const std::vector<std::uint8_t>& bytes) {
  std::array<std::uint8_t, 32> digest{};
  CC_SHA256(bytes.data(), static_cast<CC_LONG>(bytes.size()), digest.data());
  return digest;
}

bool Fail(std::string message, std::string* error) {
  if (error != nullptr) {
    *error = std::move(message);
  }
  return false;
}

std::size_t ScalarWidth(ScalarType scalar_type) {
  switch (scalar_type) {
    case ScalarType::kU8:
      return 1;
    case ScalarType::kU32:
    case ScalarType::kF32:
      return 4;
  }
  return 0;
}

unsigned char PcodecType(ScalarType scalar_type) {
  switch (scalar_type) {
    case ScalarType::kU8:
      return PCO_TYPE_U8;
    case ScalarType::kU32:
      return PCO_TYPE_U32;
    case ScalarType::kF32:
      return PCO_TYPE_F32;
  }
  return 0;
}

bool EncodePcodec(ScalarType scalar_type,
                  const Parameters& parameters,
                  const std::vector<std::uint8_t>& raw,
                  Encoded* encoded,
                  std::string* error) {
  const std::size_t width = ScalarWidth(scalar_type);
  if (width == 0 || raw.size() % width != 0) {
    return Fail("Pcodec input is not aligned to its scalar type", error);
  }
  const std::size_t count = raw.size() / width;
  const unsigned char dtype = PcodecType(scalar_type);
  const std::size_t bound = pco_standalone_guarantee_file_size(count, dtype);
  if (bound == 0) {
    return Fail("Pcodec rejected the type or element count", error);
  }
  PcoChunkConfig config{};
  config.compression_level =
      static_cast<unsigned int>(parameters.level > 0 ? parameters.level : 12);
  config.max_page_n = 0;
  encoded->bytes.resize(bound);
  std::size_t written = 0;
  const PcoError status = pco_standalone_simple_compress_into(
      raw.data(), count, dtype, &config, encoded->bytes.data(),
      encoded->bytes.size(), &written);
  if (status != PcoSuccess) {
    return Fail("Pcodec compression failed with status " +
                    std::to_string(static_cast<int>(status)),
                error);
  }
  encoded->bytes.resize(written);
  encoded->element_count = count;
  return true;
}

bool DecodePcodec(const Encoded& encoded,
                  std::vector<std::uint8_t>* raw,
                  std::string* error) {
  const std::size_t width = ScalarWidth(encoded.scalar_type);
  if (width == 0 || encoded.element_count >
                        std::numeric_limits<std::size_t>::max() / width) {
    return Fail("Pcodec decoded size overflows", error);
  }
  raw->resize(encoded.element_count * width);
  std::size_t written = 0;
  const PcoError status = pco_standalone_simple_decompress_into(
      encoded.bytes.data(), encoded.bytes.size(),
      PcodecType(encoded.scalar_type), raw->data(), encoded.element_count,
      &written);
  if (status != PcoSuccess || written != encoded.element_count) {
    return Fail("Pcodec decompression failed or returned the wrong count",
                error);
  }
  return true;
}

bool EncodeBlosc2(const Parameters& parameters,
                  const std::vector<std::uint8_t>& raw,
                  Encoded* encoded,
                  std::string* error) {
  if (raw.size() > static_cast<std::size_t>(BLOSC2_MAX_BUFFERSIZE) ||
      parameters.element_width == 0 ||
      parameters.element_width >
          static_cast<std::size_t>(std::numeric_limits<std::int32_t>::max()) ||
      raw.size() % parameters.element_width != 0) {
    return Fail("Blosc2 input size or type width is invalid", error);
  }
  if (parameters.filter != BLOSC_NOSHUFFLE &&
      parameters.filter != BLOSC_SHUFFLE &&
      parameters.filter != BLOSC_BITSHUFFLE) {
    return Fail("Blosc2 filter is not in the reversible whitelist", error);
  }

  blosc2_cparams cparams = BLOSC2_CPARAMS_DEFAULTS;
  cparams.compcode = BLOSC_ZSTD;
  cparams.clevel =
      static_cast<std::uint8_t>(parameters.level > 0 ? parameters.level : 9);
  cparams.typesize = static_cast<std::int32_t>(parameters.element_width);
  cparams.filters[BLOSC2_MAX_FILTERS - 1] =
      static_cast<std::uint8_t>(parameters.filter);
  BloscContextPtr context(blosc2_create_cctx(cparams), &blosc2_free_ctx);
  if (context == nullptr) {
    return Fail("Blosc2 failed to create a compression context", error);
  }

  encoded->bytes.resize(raw.size() + BLOSC2_MAX_OVERHEAD);
  const int written = blosc2_compress_ctx(
      context.get(), raw.data(), static_cast<std::int32_t>(raw.size()),
      encoded->bytes.data(), static_cast<std::int32_t>(encoded->bytes.size()));
  if (written <= 0) {
    return Fail("Blosc2 compression failed with status " +
                    std::to_string(written),
                error);
  }
  encoded->bytes.resize(static_cast<std::size_t>(written));
  encoded->element_count = raw.size() / parameters.element_width;
  return true;
}

bool DecodeBlosc2(const Encoded& encoded,
                  std::vector<std::uint8_t>* raw,
                  std::string* error) {
  if (encoded.raw_size >
      static_cast<std::size_t>(std::numeric_limits<std::int32_t>::max())) {
    return Fail("Blosc2 decoded size exceeds its chunk limit", error);
  }
  blosc2_dparams dparams = BLOSC2_DPARAMS_DEFAULTS;
  dparams.typesize = static_cast<std::int32_t>(encoded.parameters.element_width);
  BloscContextPtr context(blosc2_create_dctx(dparams), &blosc2_free_ctx);
  if (context == nullptr) {
    return Fail("Blosc2 failed to create a decompression context", error);
  }
  raw->resize(encoded.raw_size);
  const int written = blosc2_decompress_ctx(
      context.get(), encoded.bytes.data(),
      static_cast<std::int32_t>(encoded.bytes.size()), raw->data(),
      static_cast<std::int32_t>(raw->size()));
  if (written < 0 || static_cast<std::size_t>(written) != encoded.raw_size) {
    return Fail("Blosc2 decompression failed or returned the wrong size",
                error);
  }
  return true;
}

bool SetOpenZlParameter(ZL_Compressor* compressor,
                        ZL_CParam parameter,
                        int value,
                        std::string* error) {
  const ZL_Report report =
      ZL_Compressor_setParameter(compressor, parameter, value);
  if (ZL_isError(report)) {
    return Fail(ZL_Compressor_getErrorContextString(compressor, report), error);
  }
  return true;
}

ZL_GraphID BuildOpenZlBruteForce(ZL_Compressor* compressor,
                                 std::string* error) {
  if (!SetOpenZlParameter(compressor, ZL_CParam_formatVersion,
                          kOpenZlFormatVersion, error)) {
    return ZL_GRAPH_ILLEGAL;
  }
  const ZL_GraphID standard = ZL_GRAPH_COMPRESS_GENERIC;
  const ZL_GraphID sorted = ZL_Compressor_registerStaticGraph_fromNode1o(
      compressor, ZL_NODE_DELTA_INT, ZL_GRAPH_COMPRESS_GENERIC);
  const ZL_GraphID integer = ZL_GRAPH_FIELD_LZ;
  const std::array<ZL_GraphID, 2> bfloat_successors = {
      ZL_GRAPH_STORE,
      ZL_GRAPH_FSE,
  };
  const ZL_GraphID bfloat = ZL_Compressor_registerStaticGraph_fromNode(
      compressor, ZL_NODE_BFLOAT16_DECONSTRUCT, bfloat_successors.data(),
      bfloat_successors.size());
  const std::array<ZL_GraphID, 2> float_successors = {
      ZL_GRAPH_STORE,
      ZL_GRAPH_FSE,
  };
  const ZL_GraphID float32 = ZL_Compressor_registerStaticGraph_fromNode(
      compressor, ZL_NODE_FLOAT32_DECONSTRUCT, float_successors.data(),
      float_successors.size());
  const std::array<ZL_GraphID, 5> successors = {
      standard,
      sorted,
      integer,
      bfloat,
      float32,
  };
  auto selector = [](const ZL_Selector* selector_context,
                     const ZL_Input* input,
                     const ZL_GraphID* candidate_graphs,
                     std::size_t candidate_count) noexcept -> ZL_GraphID {
    std::size_t best_size = ZL_Input_contentSize(input);
    ZL_GraphID best_graph = ZL_GRAPH_STORE;
    for (std::size_t index = 0; index < candidate_count; ++index) {
      const ZL_Report report =
          ZL_Selector_tryGraph(selector_context, input, candidate_graphs[index])
              .finalCompressedSize;
      if (!ZL_isError(report) && ZL_validResult(report) < best_size) {
        best_size = ZL_validResult(report);
        best_graph = candidate_graphs[index];
      }
    }
    return best_graph;
  };
  ZL_SelectorDesc descriptor{};
  descriptor.selector_f = selector;
  descriptor.inStreamType = ZL_Type_numeric;
  descriptor.customGraphs = successors.data();
  descriptor.nbCustomGraphs = successors.size();
  descriptor.name = "official_numeric_array_brute_force";
  return ZL_Compressor_registerSelectorGraph(compressor, &descriptor);
}

bool EncodeOpenZl(const Parameters& parameters,
                  const std::vector<std::uint8_t>& raw,
                  Encoded* encoded,
                  std::string* error) {
  if ((parameters.element_width != 1 && parameters.element_width != 2 &&
       parameters.element_width != 4 && parameters.element_width != 8) ||
      raw.size() % parameters.element_width != 0) {
    return Fail("OpenZL numeric width is invalid", error);
  }
  CompressorPtr compressor(ZL_Compressor_create(), &ZL_Compressor_free);
  if (compressor == nullptr) {
    return Fail("OpenZL failed to create a compressor", error);
  }
  if (!SetOpenZlParameter(
          compressor.get(), ZL_CParam_compressionLevel,
          parameters.level > 0 ? parameters.level : kOpenZlDefaultLevel,
          error)) {
    return false;
  }
  const ZL_GraphID graph = BuildOpenZlBruteForce(compressor.get(), error);
  if (graph.gid == ZL_GRAPH_ILLEGAL.gid) {
    return Fail(error != nullptr && !error->empty()
                    ? *error
                    : "OpenZL failed to register the official numeric graph",
                error);
  }
  const ZL_Report select_report =
      ZL_Compressor_selectStartingGraphID(compressor.get(), graph);
  if (ZL_isError(select_report)) {
    return Fail(ZL_Compressor_getErrorContextString(compressor.get(),
                                                    select_report),
                error);
  }
  CompressionContextPtr context(ZL_CCtx_create(), &ZL_CCtx_free);
  if (context == nullptr) {
    return Fail("OpenZL failed to create a compression context", error);
  }
  const ZL_Report ref_report =
      ZL_CCtx_refCompressor(context.get(), compressor.get());
  if (ZL_isError(ref_report)) {
    return Fail(ZL_CCtx_getErrorContextString(context.get(), ref_report),
                error);
  }
  TypedRefPtr input(
      ZL_TypedRef_createNumeric(raw.data(), parameters.element_width,
                                raw.size() / parameters.element_width),
      &ZL_TypedRef_free);
  if (input == nullptr) {
    return Fail("OpenZL rejected the numeric input", error);
  }
  encoded->bytes.resize(ZL_compressBound(raw.size()));
  const ZL_Report compress_report = ZL_CCtx_compressTypedRef(
      context.get(), encoded->bytes.data(), encoded->bytes.size(), input.get());
  if (ZL_isError(compress_report)) {
    return Fail(ZL_CCtx_getErrorContextString(context.get(), compress_report),
                error);
  }
  encoded->bytes.resize(ZL_validResult(compress_report));
  encoded->element_count = raw.size() / parameters.element_width;
  return true;
}

bool DecodeOpenZl(const Encoded& encoded,
                  std::vector<std::uint8_t>* raw,
                  std::string* error) {
  const ZL_Report size_report =
      ZL_getDecompressedSize(encoded.bytes.data(), encoded.bytes.size());
  if (ZL_isError(size_report) || ZL_validResult(size_report) != encoded.raw_size) {
    return Fail("OpenZL frame is invalid or reports the wrong size", error);
  }
  raw->resize(encoded.raw_size);
  TypedBufferPtr output(
      ZL_TypedBuffer_createWrapNumeric(raw->data(),
                                      encoded.parameters.element_width,
                                      raw->size()),
      &ZL_TypedBuffer_free);
  if (output == nullptr) {
    return Fail("OpenZL rejected the numeric output buffer", error);
  }
  DecompressionContextPtr context(ZL_DCtx_create(), &ZL_DCtx_free);
  if (context == nullptr) {
    return Fail("OpenZL failed to create a decompression context", error);
  }
  const ZL_Report report = ZL_DCtx_decompressTBuffer(
      context.get(), output.get(), encoded.bytes.data(), encoded.bytes.size());
  if (ZL_isError(report)) {
    return Fail(ZL_DCtx_getErrorContextString(context.get(), report), error);
  }
  return true;
}

}  // namespace

bool Encode(Codec codec,
            ScalarType scalar_type,
            const Parameters& parameters,
            const std::vector<std::uint8_t>& raw,
            Encoded* encoded,
            std::string* error) {
  if (encoded == nullptr || raw.empty()) {
    return Fail("codec input and output must be non-empty", error);
  }
  Encoded candidate;
  candidate.codec = codec;
  candidate.scalar_type = scalar_type;
  candidate.parameters = parameters;
  candidate.raw_size = raw.size();
  candidate.raw_sha256 = Sha256(raw);
  bool success = false;
  switch (codec) {
    case Codec::kPcodec:
      success = EncodePcodec(scalar_type, parameters, raw, &candidate, error);
      break;
    case Codec::kBlosc2:
      success = EncodeBlosc2(parameters, raw, &candidate, error);
      break;
    case Codec::kOpenZl:
      success = EncodeOpenZl(parameters, raw, &candidate, error);
      break;
  }
  if (!success) {
    return false;
  }
  *encoded = std::move(candidate);
  return true;
}

bool Decode(const Encoded& encoded,
            std::vector<std::uint8_t>* raw,
            std::string* error) {
  if (raw == nullptr || encoded.bytes.empty() || encoded.raw_size == 0) {
    return Fail("encoded payload or output buffer is invalid", error);
  }
  std::vector<std::uint8_t> candidate;
  bool success = false;
  switch (encoded.codec) {
    case Codec::kPcodec:
      success = DecodePcodec(encoded, &candidate, error);
      break;
    case Codec::kBlosc2:
      success = DecodeBlosc2(encoded, &candidate, error);
      break;
    case Codec::kOpenZl:
      success = DecodeOpenZl(encoded, &candidate, error);
      break;
  }
  if (!success) {
    return false;
  }
  if (candidate.size() != encoded.raw_size ||
      Sha256(candidate) != encoded.raw_sha256) {
    return Fail("decoded payload failed SHA-256 verification", error);
  }
  *raw = std::move(candidate);
  return true;
}

const char* CodecName(Codec codec) {
  switch (codec) {
    case Codec::kPcodec:
      return "pcodec";
    case Codec::kBlosc2:
      return "c-blosc2";
    case Codec::kOpenZl:
      return "openzl";
  }
  return "unknown";
}

}  // namespace pw::codecbench
