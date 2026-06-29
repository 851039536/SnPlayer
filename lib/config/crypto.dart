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

/// 流式加解密缓冲区大小（512KB）
const int bufferSize = 512 * 1024;

/// PBKDF2 Salt 在文件头中的偏移量
const int saltOffset = 16;

/// 密文数据在文件中的起始偏移量
const int ciphertextOffset = 64;

/// AES-CTR 块大小（固定 16 字节）
const int aesBlockSize = 16;

/// 缩略图宽度（像素）
const int thumbnailWidth = 280;

/// 缩略图高度（像素）
const int thumbnailHeight = 150;

/// 缩略图 JPEG 质量（0-100）
const int thumbnailQuality = 80;

/// 缩略图分批加载每批数量
const int thumbnailBatchSize = 3;

/// 播放临时文件自动删除延迟（毫秒）
const int playCacheDeleteDelayMs = 30000;

/// 安全删除零覆写块大小（4KB）
const int safeDeleteBlockSize = 4096;

/// 安全删除重试间隔序列（毫秒）
const List<int> safeDeleteRetryDelays = [3000, 6000, 12000, 24000, 30000];

/// 加密视频存储根目录（相对 /sdcard/Download/）
const String lockVideoDirName = 'MewTool/LockVideo';

/// 解密导出目录（相对 /sdcard/Download/）
const String unlockVideoDirName = 'MewTool/UnLockVideo';

/// 播放缓存目录（相对应用缓存）
const String playCacheDirName = 'play_cache';

/// 文件夹元数据文件名
const String foldersJsonFileName = '.folders.json';
