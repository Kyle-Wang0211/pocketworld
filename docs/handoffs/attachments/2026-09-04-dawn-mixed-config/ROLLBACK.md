# Dawn 归档回退件(2026-09-04)

`libwebgpu_dawn.a`(iOS,668MB)与 6 月 21 日钉定版的**唯一差别**就是一个对象:
`PhysicalDeviceMTL.o`(补登混合子组矩阵配置)。此处保留**旧版对象**,
需要回退时:

    ar r <libwebgpu_dawn.a> PhysicalDeviceMTL.pinned-0621.o && ranlib <...>
    # 之后 SHA 应回到 625cf65dded708ad1abd3dc92f3b47c3c90c384f508676b56303f9341d301b42

668MB 的整包备份已删(磁盘压力),因为:①产品级回退走 git 里已提交的
旧 PWOfficialSfm.xcframework 二进制,不需要重建;②归档级回退只需这 2.7MB。
