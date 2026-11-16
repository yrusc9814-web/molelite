# 素材

## fonts/Bravura.otf
- Bravura，Steinberg Media Technologies 出品的 SMuFL 标准音乐字体。
- 许可：SIL Open Font License 1.1（全文见 fonts/OFL.txt）。原样随包，未修改。
- 用途：五线谱装饰里的谱号、变音记号、符头（UI/NoteStaff.swift）。

五线、符干、符杠、加线由代码绘制；乐句为自编，动效思路参考 Kimi 会员页（未拷贝其代码或素材）。

## fonts/NotoSerifSC-{SemiBold,Regular}-subset.otf
- 思源宋体（Noto Serif SC），Adobe / Google 出品。许可：SIL OFL 1.1。
- 已子集化：保留 ASCII + 源码中出现的汉字 + GB2312 一级常用字（约 3800 字），缺字由系统字体自动补。
- 用途：页面标题、副标题（UI/Theme.swift 的 Typo）。

## fonts/EBGaramond-Medium-subset.ttf
- EB Garamond（Georg Duffner / Octavio Pardo）。许可：SIL OFL 1.1。
- 由可变字体实例化为 Medium（字重 500），仅保留 ASCII，改了内部名称为 EBGaramond-Medium（OFL 允许修改后改名使用）。
- 用途：标题里的数字和单位。

背景极光、微尘由代码绘制（UI/Theme.swift 的 PageBackground）。
