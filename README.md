# SourceEditor

一个以渲染质量、可预测的编辑开销和 macOS 原生输入为优先的代码编辑器组件。

**Distributed as a Swift Package; the libraries, demo, and checks are implemented in Objective-C.** Only the required `Package.swift` manifest uses Swift. Supports macOS 14+; the core has no third-party dependencies or unsafe compiler flags. The optional Tree-sitter module downloads pinned C runtime and grammar sources during initialization, without a Swift wrapper or remote SwiftPM dependency.

## 开始使用

```sh
./script/bootstrap.sh
swift build
./script/build_and_run.sh
./script/test.sh
```

`bootstrap.sh` requires Python 3 and curl. It downloads only missing dependencies,
verifies their pinned SHA-256 checksums, and caches them outside Git. The demo and
full test scripts initialize dependencies automatically and work offline once the
sources are installed. See [Vendor/README.md](Vendor/README.md) for the manifest
and cache behavior.

To build or check only the core from a fresh checkout without downloading anything:

```sh
SOURCE_EDITOR_CORE_ONLY=1 swift build --target SourceEditor
./script/test.sh --core-only
```

`SourceEditor` is the standalone editor library; `SourceEditorTreeSitter` is the optional highlighting library. The AppKit demo defaults to Plain Text. Use the language control in the bottom status bar or the **Syntax** menu to select Plain Text, JSON, or JavaScript without replacing the document or clearing Undo. The status bar uses an `NSVisualEffectView` over the scrolling editor, with separate views for the indicators and dividers. Scroll insets keep the last line and caret above it. If a highlighter cannot initialize, the demo falls back to Plain Text.

The status bar items and selectable languages are configurable. `SEStatusBarView.items` sets the items and their order (`line`, `column`, `lineCount`, `language`; the language item sits at the trailing edge). `languageTitles` is the only list the user can pick from. An empty list hides the language item, a single title shows a fixed label that can't be clicked, and two or more show a pop-up. When nothing is left to show, `hasVisibleItems` is `NO`; the demo then hides the bar and removes its scroll insets. The demo reads both settings from user defaults, so you can pass them at launch. Each takes a comma-separated string or an array, and an empty value means none:

```sh
open dist/SourceEditorDemo.app --args -SEStatusBarItems 'line,column,language' -SESyntaxLanguages 'json,javascript'
open dist/SourceEditorDemo.app --args -SEStatusBarItems ''        # no status bar
open dist/SourceEditorDemo.app --args -SESyntaxLanguages 'json'    # fixed to JSON
```

The demo starts with the first listed language, and shows the **Syntax** menu only when there are at least two languages to choose from.

运行脚本在 `dist/` 中生成本地 `.app` 再启动，支持 `--verify`、`--debug`、`--logs` 和 `--telemetry`。Codex 的 Run 操作也指向同一脚本。

已有窗口中有编辑内容时，可用 `./script/build_and_run.sh --preview` 启动独立的新构建预览；它保留现有窗口及其撤销历史，每次预览也使用独立的 bundle 路径。

示例是组件宿主，内容只保留在内存中，关闭后不保存。文件管理应由宿主应用负责。

## 代码风格

Objective-C 源码、公开头文件、Demo 和检查程序以 [WebKit Code Style Guidelines](https://webkit.org/code-style-guidelines/) 为基础，使用 4 空格缩进。按本项目约定，方法／函数的左大括号放在签名同一行，方法体从下一行开始，方法之间保留空行。项目的 `.clang-format` 禁止单行函数、单行控制语句和单行 Block。

运行 `./script/format.sh` 统一格式，或运行 `./script/format.sh --check` 检查是否符合配置。脚本优先使用 PATH 中的 `clang-format`，也支持 Xcode 自带的版本。

## 嵌入组件

在使用该 Package 的 Objective-C target 中启用 Clang Modules，然后：

```objc
@import SourceEditor;

NSScrollView *scroll = [SEEditorView scrollableEditorView];
SEEditorView *editor = (SEEditorView *)scroll.documentView;
editor.font = [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightRegular];
editor.string = @"// Hello, native editor.\n";
self.view = scroll;
```

也可直接创建 `SEEditorView`，作为自己的 `NSScrollView.documentView`。编辑器及其属性在主线程访问。

## 可选 JSON / JavaScript 高亮

宿主只依赖 `SourceEditor` product 时，不会编译或链接 Tree-sitter，编辑器默认 `syntaxHighlighter == nil`，完整的基础编辑体验继续工作。需要高亮时，再给宿主 target 添加 `SourceEditorTreeSitter` product：

```objc
@import SourceEditor;
@import SourceEditorTreeSitter;

NSError *error = nil;
editor.syntaxHighlighter = [[SETreeSitterHighlighter alloc]
    initWithLanguage:SETreeSitterLanguageJavaScript error:&error];
// JSON 使用 SETreeSitterLanguageJSON。

// 随时恢复纯文本；也会取消请求并清除已应用的高亮颜色。
editor.syntaxHighlighter = nil;
```

初始化失败会返回 `nil` 和错误，宿主可继续使用纯文本编辑器。一个 provider 对应一个编辑器／文档；多个窗口分别创建实例。

依赖方向只有 `SourceEditorTreeSitter → SourceEditor`。核心只定义 `SESyntaxHighlighter` 协议、`SESyntaxToken`、`SETextEdit` 和 `SESyntaxHighlightResult`，不包含 Tree-sitter 头文件、语法树类型、语言枚举或解析器生命周期。其他引擎实现同一个协议即可接入。

高亮处理过程：

1. 主线程提交 O(1) 的 Rope 快照、精确编辑描述和当前可见行前后各 6 行的查询范围。
2. provider 在私有串行队列构建／增量更新语法树；首次解析扫描全文，后续使用 `ts_tree_edit` 和旧树复用结构。连续请求合并，过期解析可取消。
3. 查询只返回与可见范围相交的 capture，保留跨行注释／模板字符串的完整文档范围；无需为整份文档构建 attributed text。
4. 主线程校验文档 revision 和请求序号，丢弃过期结果。语义区间分配到行缓存，仅颜色实际变化的行重建 `CTLine`；其余行继续复用。

解析器通过 C 输入回调直接读取 Rope 的 UTF-16 LE 分块，不复制整份文本或转换整份 UTF-8。Tree-sitter 字节位置／列数是 UTF-16 单元数的两倍；分块边界会避开 surrogate pair 中间。快照携带文档标识，防止不同文档的相同 revision 错用旧树。

颜色属于编辑器的 `SESyntaxTheme`，解析模块只返回语义 token。换主题不会重新解析；缺少配置的 token 使用普通文字颜色。默认主题使用系统动态颜色，支持浅色／深色外观：

```objc
editor.syntaxTheme = [[SESyntaxTheme alloc] initWithForegroundColors:@{
    SESyntaxTokenKeyword : NSColor.systemPurpleColor,
    SESyntaxTokenString : NSColor.systemRedColor,
    SESyntaxTokenComment : NSColor.secondaryLabelColor,
}];
```

目前提供 JSON key／字符串／转义／数字／常量，以及 JavaScript 关键字、函数、类、属性、注释、正则和模板插值。查询文件位于 `Sources/SourceEditorTreeSitter/Queries`，使用结构 capture，不依赖未实现的 query predicate 或语言服务。

Pinned versions, archive checksums, and extraction paths are recorded in `Vendor/versions.json`; licenses are preserved in the downloaded sources and `Vendor/THIRD_PARTY_NOTICES.txt`.

SwiftPM 会给宿主应用嵌入查询 resource bundle；本项目运行脚本也会将它和第三方声明复制到 `.app/Contents/Resources`。手工分发二进制的宿主应同样携带这两个资源。

## 架构取舍

采用 **AppKit + Core Text**。Core Text 负责系统字体排版、字体回退和文字绘制；组件负责文本存储、可见区域、交互和失效管理。选择它是为了掌握这些边界，性能是否接近 Zed / Sublime 仍需后续实测。

第一版就将存储、可见行几何和排版缓存分离，并把 Undo 与输入法放入最小闭环。这样可以在基础交互正确的前提下继续优化。

| 模块 | 职责 | 当前实现 |
| --- | --- | --- |
| `SETextBuffer` | UTF-16 存储、行索引、独立快照 | 不可变节点的 AVL Rope，叶块最多 4096 个 UTF-16 单元；子树汇总长度和换行数 |
| `SEViewport` | 可见行范围 | 固定行高，根据滚动区域计算可见行及前后各 6 行；独立于 Core Text |
| `SELineLayoutCache` | 排版、命中测试、选区几何 | 按行按需创建 `CTLine`；局部编辑只失效相交行，后续行的缓存随行号平移 |
| `SEEditorView` | AppKit 交互与组合 | `NSTextInputClient`、标准编辑命令、Undo、鼠标选区、滚动协调 |
| `SESyntaxHighlighter` / `SESyntaxTheme` | 可替换的高亮协议／呈现策略 | 语义 UTF-16 区间、异步版本校验、颜色与解析分离 |
| `SourceEditorTreeSitter`（可选） | JSON / JavaScript 解析与查询 | 固定 C grammar、后台增量语法树、viewport capture 查询 |

编辑不会构造整个文件的 `NSAttributedString`。行定位沿树查找，读取和替换只访问相交的块；快照共享不可变节点，复制本身为 O(1)。读取 `editor.string` / `buffer.string` 则会显式物化整份文档，为 O(N)，不应放进逐键回调中。

文字和选区分别绘制在**可见窗口大小**的 backing layer 上，光标使用独立 `CALayer`。文档视图可以很高，绘制表面始终只有一个 viewport 大小。移动选区和光标闪烁不失效 `CTLine`。

选区先求各行视觉区段与行尾扩展的并集，消除内部边，再沿完整轮廓将外凸角和跨行内凹衔接都处理成连续曲率圆角。每个转折由两段三次贝塞尔曲线组成：与直边相接处曲率为零，两段曲线中点的一阶、二阶导数一致。默认圆角尺度为 4 pt，短边自动收缩。

整个选区路径只抗锯齿填充一次，内部没有矩形接缝。几何计算按可见行的水平区段进行，不分配文档大小的像素网格；视口上下各带一行轮廓上下文，避免裁剪边缘出现假的圆角。双向文本中真正未选中的间隔、孔洞和分离区段会保留。

当前缓存以逻辑行号寻址，并在每次编辑时根据旧行范围和行数差同时调整布局与语义样式，正确性依赖所有编辑经过视图的事务入口。字体、Tab 宽度和外观变化清空布局缓存；语义样式仍可复用。高亮结果用 revision／请求序号校验，按行比较实际样式，不以全局 revision 作为所有 `CTLine` 的失效键。

## 首版已实现

- Core Text 绘制、系统等宽字体、字体回退、系统浅色／深色适配。
- 双向滚动、固定行号、当前行底色、独立光标闪烁。
- 括号作用域引导线：光标所在的最内层跨行 `()`／`[]`／`{}` 内，在起始行的缩进处画一条竖线，只覆盖括号之间的行（`showsScopeGuide`，默认开启）。
- 输入、删除、Tab、继承前导缩进的换行、剪切／复制／粘贴、Undo/Redo。
- 鼠标拖选、双击选词、三击／点行号选行、越界拖选自动滚动。
- 字素边界移动与删除，避免拆开 Emoji、ZWJ 序列和组合字符；CRLF 作为一个编辑边界。
- 方向键、Shift 选区、Option 词移动、Command 行首／行尾／文档边界、翻页。
- 输入法标记文字、提交、取消、屏幕坐标查询；一次组合输入合并为一个撤销事务。
- 只读开关、文本／选区通知、基础 Accessibility 文本与选区接口。
- 可选 JSON／JavaScript 语法高亮、独立主题、后台增量解析与 viewport 查询。

所有公开位置和 `NSRange` **都按 UTF-16 单元计数**，不是 UTF-8 字节或可见字符数。行号从 0 开始；LF 和 CRLF 原样保留；末尾换行产生最后一个空行。可选适配器内部负责 Tree-sitter 字节坐标的转换。

## 验证

`script/test.sh` 运行纯 Objective-C 的 `SourceEditorChecks` 和 `SourceEditorTreeSitterChecks`。`script/test.sh --core-only` 只构建／运行不链接 Tree-sitter 的核心检查。这里使用 executable checks，因为 SwiftPM 的 XCTest 发现机制不能直接运行 Objective-C 测试用例；运行 `swift test` 不会执行这些检查。

检查包括：

- 12,000 次随机替换，与 `NSMutableString` 对照；另外连续插入 3,000 次验证增长路径；检查行索引、范围读取和快照独立性。
- Emoji／组合字符／CRLF 删除、Undo/Redo、纵向移动的目标列保持、自动缩进及只读模式。
- 标记文字更新、替换选区、提交／取消、整次组合输入的 Undo/Redo、输入法范围与屏幕坐标往返。
- 作用域引导线：与独立的栈匹配参考实现做随机对照（含跨读取分块和扫描上限）、编辑后跟随、像素位置与覆盖行数。
- Core Text 字素边界命中、Tab 前进、未变行缓存复用、选区变化不重排。
- 十万行文档的可见行缓存范围、局部编辑失效范围、滚动和文档缩短后的绘制表面大小。
- 输出十万行缓冲区的构建与随机插入／删除耗时；这是 **Debug 的存储层微基准**，不代表按键到屏幕显示的端到端延迟。
- 注入替代高亮器、实际 Core Text 颜色、未变样式的缓存复用、过期结果丢弃、移除 provider、主题切换不解析、CRLF／UTF-16 编辑坐标。
- JSON 和 JavaScript 各 120 次随机 Unicode／换行编辑，将增量结果逐次与全量解析对比；覆盖不完整的中间语法状态。
- 模板嵌套、正则、Emoji 横跨输入块、两万行文档的范围查询、滚动不重解析、跨行 capture、文档身份、请求合并和取消。

已启动示例检查实际文字绘制、原生快捷键撤销／重做、Unicode 粘贴和横向滚动。协议检查不代替真实输入法测试，中文／日文候选窗定位和连续组合输入仍需逐项手测。

## 明确的边界与后续顺序

1. **先补输入与性能证据。** 用真实拼音／日文输入法检查候选窗、选区替换与取消；用 Instruments 测输入和滚动帧时间，记录输入到呈现的 p50/p95。普通连续键入目前按每次插入记录 Undo，后续增加符合原生习惯的合并；大粘贴撤销历史还需要按内存预算淘汰。
2. **超长行分段排版。** 当前可见逻辑行仍整体生成一个 `CTLine`，百万字符单行会阻塞主线程；字素导航和选区几何也按整行处理。需要带 shaping 上下文的分段、横向可见范围索引和明确预算，不能仅把字符串硬切成独立 glyph 段。当前横向滚动宽度随已访问行增长，局部删除后可能保留较宽滚动范围。
3. **软折行。** 当前为不折行代码布局；换行输入已支持。增加软折行时引入视觉行／高度索引和宽度版本，替换固定行高的逻辑行几何。还需完善混合双向文本的视觉方向移动、光标 affinity 与精细选区；当前系统 shaping 不等于完整的双向编辑行为。
4. **语言服务。** 现有可选高亮协议可继续扩展其他解析器或语言，再考虑诊断、补全、LSP 和多光标。

作用域引导线按字符匹配括号，字符串和注释里的括号同样计数；为限定每次移动光标的开销，从光标起向两侧各最多扫描 131,072 个 UTF-16 单元，超出时不显示。后续可改用语法树判定。

独立 CR 换行、矩形选区、代码折叠、LSP、完整 VoiceOver 参数化导航暂未实现。高亮目前是结构语法高亮，不做作用域绑定或跨语言注入。适配器受 Tree-sitter 32 位字节坐标约束；超出范围、单次查询超过 20,000 个 capture 或查询匹配预算时，该范围回退纯文本。以上边界不影响继续完善当前组件，但首版还不能宣称达到成熟编辑器的性能或交互覆盖率。

参考：[Core Text 命中测试](https://developer.apple.com/documentation/coretext/ctlinegetstringindexforposition(_:_:))、[NSTextInputClient](https://developer.apple.com/documentation/appkit/nstextinputclient?language=objc)、[SwiftPM PackageDescription](https://docs.swift.org/package-manager/PackageDescription/PackageDescription.html)。
