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

/// 保留字段长度（32 字节，全零）
const int reservedSize = 32;

/// PBKDF2 迭代次数
const int pbkdf2Iterations = 100000;

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

/// 并行解密最大 Isolate 数
const int parallelDecryptMaxIsolates = 4;

/// 并行解密中等 Isolate 数（2 路并行，用于 64-256MB 文件）
const int parallelDecryptMidIsolates = 2;

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
