const expectedLeptonJxlSourceBytes = 2725495;
const expectedLeptonJxlSourceSha256 =
    'a1cb8de1d3b91edbb7e05233c7930200c46e04554c3651153e267e5abd262138';

bool isExpectedLeptonJxlBenchmarkInput({
  required int bytes,
  required String sha256Hex,
}) =>
    bytes == expectedLeptonJxlSourceBytes &&
    sha256Hex == expectedLeptonJxlSourceSha256;

bool isLeptonProductionEligible({
  required bool jxlExact,
  required bool leptonExact,
  required int jxlArchiveBytes,
  required int leptonArchiveBytes,
}) => jxlExact && leptonExact && leptonArchiveBytes < jxlArchiveBytes;
