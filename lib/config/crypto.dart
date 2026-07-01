/// 加密常量配置
/// 所有加密参数与 MewTool 原版保持一致，确保 .enc 文件格式兼容

/// 默认加密密码（UTF-8 编码后用于 PBKDF2 密钥派生）
const String defaultPassword = 'SN-Video-Editor-2026-Default-Key!';

/// AES 密钥长度（256 位 = 32 字节）
const int keyLength = 32;

/// IV（初始化向量）长度（128 位 = 16 字节）
const int ivLength = 16;

/// PBKDF2 Salt 长度（16 字节）
const int saltLength = 16;

/// 加密文件头总长度（IV + Salt + 保留字段 = 64 字节）
const int headerSize = 64;

/// 格式版本号（v2: 0x02）
const int versionByte = 0x02;

/// 版本号在文件头中的偏移量
const int versionOffset = 32;

/// 保留字段长度（31 字节，全零）
const int reservedSize = 31;

/// PBKDF2 迭代次数（v2: 1 万次）
const int pbkdf2Iterations = 10;

/// 流式加解密缓冲区大小（4MB）
/// 从 512KB 提升至 4MB，减少系统调用次数约 87.5%，提升 I/O 吞吐
const int bufferSize = 4 * 1024 * 1024;

/// PBKDF2 Salt 在文件头中的偏移量
const int saltOffset = 16;

/// 密文数据在文件中的起始偏移量
const int ciphertextOffset = 64;

/// AES-CTR 块大小（固定 16 字节）
const int aesBlockSize = 16;

/// 缩略图宽度（像素，匹配网格卡片显示宽度）
const int thumbnailWidth = 480;

/// 缩略图高度（像素，16:9 比例）
const int thumbnailHeight = 270;

/// 缩略图 JPEG 质量（0-100，60 在 480×270 分辨率下与 95 肉眼无差异，文件体积缩减约 60%）
const int thumbnailQuality = 60;

/// 部分解密提取缩略图的最大字节数（30MB）
///
/// AES-256-CTR 流加密支持从任意位置解密。
/// 视频首帧 + moov atom 通常在前 5-10MB 内，30MB 留足余量。
const int partialDecryptMaxBytes = 30 * 1024 * 1024;

/// 缩略图分批加载每批数量
const int thumbnailBatchSize = 8;

/// 播放临时文件自动删除延迟（毫秒）
const int playCacheDeleteDelayMs = 30000;

/// 安全删除零覆写块大小（4KB）
const int safeDeleteBlockSize = 4096;

/// 安全删除重试间隔序列（毫秒）
const List<int> safeDeleteRetryDelays = [3000, 6000, 12000, 24000, 30000];

// ═══════════════════════════════════════════════════════════
// 并行解密配置
// ═══════════════════════════════════════════════════════════

/// 触发并行解密的最小文件大小（64MB）
/// 低于此值使用单 Isolate 串行解密，避免 Isolate 启动开销 > 并行收益
const int parallelDecryptMinFileSize = 64 * 1024 * 1024;

/// 中等文件阈值（256MB），超过此值使用 4 Isolate，否则用 2 Isolate
const int parallelDecryptMidFileSize = 256 * 1024 * 1024;

/// 并行解密最大 Isolate 数（4 路并行，用于 256-512MB 文件）
/// 与 concurrency=2 配合，分 2 批启动，每批 2 个，安全可控
const int parallelDecryptMaxIsolates = 4;

/// 并行解密中等 Isolate 数（2 路并行，用于 64-256MB 文件）
const int parallelDecryptMidIsolates = 2;

/// 大文件阈值（512MB），超过此值使用 6 路并行解密
const int parallelDecryptLargeFileSize = 512 * 1024 * 1024;

/// 并行解密大文件 Isolate 数（6 路并行，用于 >512MB 文件）
/// 配合 concurrency=2，分 3 批启动，每批 2 个 Isolate，内存安全
const int parallelDecryptLargeIsolates = 6;

/// 并行解密最大并发数（同一时间最多运行的 Isolate 数）
/// 分批启动避免瞬时内存压力过大
const int parallelDecryptMaxConcurrency = 2;

/// 加密视频存储根目录（相对 /sdcard/Download/）
const String lockVideoDirName = 'MewTool/LockVideo';

/// 解密导出目录（相对 /sdcard/Download/）
const String unlockVideoDirName = 'MewTool/UnLockVideo';

/// 播放缓存目录（相对应用缓存）
const String playCacheDirName = 'play_cache';

/// 缩略图磁盘缓存目录（相对应用缓存）
const String thumbCacheDirName = 'thumb_cache';

/// 缩略图缓存过期天数
const int thumbCacheExpireDays = 7;

/// 文件夹元数据文件名
const String foldersJsonFileName = '.folders.json';

// ═══════════════════════════════════════════════════════════
// 流式解密配置
// ═══════════════════════════════════════════════════════════

/// 流式解密 HTTP 响应处理块大小（256KB）
///
/// 每处理此大小的数据后让出事件循环（await Future.delayed(Duration.zero)），
/// 防止长时间同步解密阻塞 UI 线程。256KB 块约 5-25ms，用户无感知。
const int streamingChunkSize = 256 * 1024;

/// 内存块缓存粒度（512KB，由 StreamingDecryptProxy._decryptBlockSize 决定）
///
/// 解密后的数据按此粒度缓存，seek 回退或重复请求时直接命中内存。
/// 注意：实际缓存粒度已改为 512KB（StreamingDecryptProxy 内部常量），
/// 此常量当前仅作为文档参考，未被代码使用。
const int streamingBlockSize = 512 * 1024;

/// 内存块缓存上限（128 块 × 512KB = 64MB）
///
/// LRU 策略淘汰最久未访问的块，控制内存占用。
/// 块粒度随 _decryptBlockSize 调整为 512KB，块数相应增加以维持总量。
const int streamingMaxCacheBlocks = 128;

/// 磁盘播放缓存总上限（500MB）
///
/// 超过此值时按最旧优先策略清理 play_cache/ 中的缓存文件。
const int playCacheMaxSize = 500 * 1024 * 1024;

/// 磁盘播放缓存过期天数（3 天）
const int playCacheExpireDays = 3;

/// 流式解密代理绑定地址
const String streamingProxyHost = '127.0.0.1';

/// 流式解密代理 URL 路径
const String streamingProxyPath = '/video';

/// 流式解密节流延迟（毫秒）
///
/// burst 块之后每块等待此时间。这是 **localhost 回环下唯一有效的速率限制**：
/// - `flush()` 在 127.0.0.1 上几乎零延迟（数据瞬间进入播放器内部缓冲区），
///   不提供实质背压。
/// - 无节流时解密器以 ~20MB/s 灌入，远超播放器消费速率（1080p ~1MB/s），
///   导致 `pipelineFull: too many frames in pipeline` — 解码管道溢出、帧堆积。
/// - 15ms/512KB ≈ 34MB/s，仍远高于播放所需，但给了播放器消化时间。
///
/// seek 后尤其关键：播放器重建解码管道期间无法消费数据，节流防止灌爆。
const int streamingThrottleDelayMs = 15;

/// 流式解密爆发块数（免延迟）
///
/// 前 8 块（512KB×8=4MB）零延迟发出，覆盖 ExoPlayer 起播和 seek 恢复所需
/// 的最小数据量。从 16 降为 8：seek 后播放器重建解码管道期间最脆弱，
/// 8MB 瞬间灌入容易触发 pipelineFull，4MB 足够起播且更安全。
const int streamingBurstBlocks = 8;
