#!/bin/zsh
# Mac 开发/测试用 dylib(App 内走 ffiPlugin 静态链接,不用这个)
cd "$(dirname "$0")/.."
mkdir -p native
clang -O2 -dynamiclib -o native/libpw_vt_encoder.dylib src/pw_vt_encoder.c -framework VideoToolbox -framework CoreMedia -framework CoreVideo -framework CoreFoundation
clang -O2 -dynamiclib -o native/libpw_vt_decoder.dylib src/pw_vt_decoder.c -framework VideoToolbox -framework CoreMedia -framework CoreVideo -framework CoreFoundation
clang -O2 -dynamiclib -o native/libpw_jpeg_cvpb.dylib src/pw_jpeg_cvpb.c -framework ImageIO -framework CoreGraphics -framework CoreVideo -framework CoreFoundation
clang -O2 -dynamiclib -o native/libpw_nv12_jpeg.dylib src/pw_nv12_jpeg.c -framework ImageIO -framework CoreGraphics -framework CoreVideo -framework VideoToolbox -framework CoreMedia -framework CoreFoundation
echo done
