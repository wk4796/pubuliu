#!/bin/bash

# =================================================================
#   图片画廊 专业版 - 一体化部署与管理脚本 (v1.3.0 真正完整版)
#
#   作者: 编码助手 (经 Gemini Pro 优化)
#   v1.3.0 更新:
#   - 新增(核心): 后台增加独立的“站点统计”板块，提供专业的仪表盘功能。
#   - 新增(统计): 实现运行天数、浏览量、下载量、流量估算、热门下载等统计。
#   - 优化(后台): 后台重构为多页面板块化布局，导航更清晰，扩展性更强。
#   - 优化(性能): 统计数据采用内存缓冲、定时写入策略，降低硬盘I/O。
#   - 包含 v1.2.0 及之前所有功能：动态2FA管理、响应式布局、回收站、备份恢复等。
# =================================================================

# --- 配置 ---
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color
PROMPT_Y="(${GREEN}y${NC}/${RED}n${NC})"

SCRIPT_VERSION="1.3.0"
APP_NAME="image-gallery"

# --- 路径设置 ---
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
INSTALL_DIR="${SCRIPT_DIR}/image-gallery-app"
BACKUP_DIR="${SCRIPT_DIR}/backups"


# --- 核心功能：文件生成 ---
generate_files() {
    echo -e "${YELLOW}--> 正在创建项目目录结构: ${INSTALL_DIR}${NC}"
    mkdir -p "${INSTALL_DIR}/public/uploads"
    mkdir -p "${INSTALL_DIR}/public/cache"
    mkdir -p "${INSTALL_DIR}/data"
    
    cd "${INSTALL_DIR}" || { echo -e "${RED}错误: 无法进入安装目录 '${INSTALL_DIR}'。${NC}"; return 1; }

    echo "--> 正在生成 data/categories.json..."
cat << 'EOF' > data/categories.json
[
  "未分类"
]
EOF

    echo "--> 正在生成 data/analytics.json (统计数据文件)..."
cat << 'EOF' > data/analytics.json
{
  "total_views": 0,
  "total_downloads": 0,
  "traffic_sent_bytes": 0,
  "unique_ips": {},
  "image_download_counts": {}
}
EOF

    echo "--> 正在生成 package.json..."
cat << 'EOF' > package.json
{
  "name": "image-gallery-pro",
  "version": "13.0.0",
  "description": "A high-performance, full-stack image gallery application with all features.",
  "main": "server.js",
  "scripts": {
    "start": "node server.js"
  },
  "dependencies": {
    "cookie-parser": "^1.4.6",
    "dotenv": "^16.3.1",
    "express": "^4.18.2",
    "jsonwebtoken": "^9.0.2",
    "multer": "^1.4.5-lts.1",
    "otplib": "^12.0.1",
    "sharp": "^0.33.3",
    "uuid": "^9.0.1"
  }
}
EOF

    echo "--> 正在生成后端服务器 server.js..."
cat << 'EOF' > server.js
const express = require('express');
const multer = require('multer');
const path = require('path');
const fs = require('fs').promises;
const { v4: uuidv4 } = require('uuid');
const cookieParser = require('cookie-parser');
const jwt = require('jsonwebtoken');
const sharp = require('sharp');
const { authenticator } = require('otplib');
require('dotenv').config();

// --- App & Config ---
const app = express();
const PORT = process.env.PORT || 3000;
const ADMIN_USERNAME = process.env.ADMIN_USERNAME || 'admin';
const ADMIN_PASSWORD = process.env.ADMIN_PASSWORD || 'password';
const JWT_SECRET = process.env.JWT_SECRET;
const TWO_FACTOR_ENABLED = process.env.TWO_FACTOR_ENABLED === 'true';
const TWO_FACTOR_SECRET = process.env.TWO_FACTOR_SECRET;
const AUTH_TOKEN_NAME = 'auth_token';
const TEMP_TOKEN_NAME = 'temp_token';
const UNCATEGORIZED = '未分类';

// --- Paths ---
const dbPath = path.join(__dirname, 'data', 'images.json');
const categoriesPath = path.join(__dirname, 'data', 'categories.json');
const analyticsPath = path.join(__dirname, 'data', 'analytics.json');
const uploadsDir = path.join(__dirname, 'public', 'uploads');
const cacheDir = path.join(__dirname, 'public', 'cache');

// --- Analytics ---
const SERVER_START_TIME = new Date();
let statsData = {};
let statsBuffer = { views: 0, downloads: 0, traffic: 0, ips: new Set(), imgDownloads: {} };
const FLUSH_INTERVAL = 60000; // Flush stats to disk every 60 seconds

const loadStats = async () => {
    try {
        await fs.access(analyticsPath);
        const data = await fs.readFile(analyticsPath, 'utf-8');
        statsData = JSON.parse(data);
    } catch (err) {
        statsData = { total_views: 0, total_downloads: 0, traffic_sent_bytes: 0, unique_ips: {}, image_download_counts: {} };
        await fs.writeFile(analyticsPath, JSON.stringify(statsData, null, 2));
    }
};

const flushStatsToDisk = async () => {
    if (Object.values(statsBuffer).every(val => (val instanceof Set ? val.size === 0 : (typeof val === 'object' ? Object.keys(val).length === 0 : val === 0)))) return;
    statsData.total_views = (statsData.total_views || 0) + statsBuffer.views;
    statsData.total_downloads = (statsData.total_downloads || 0) + statsBuffer.downloads;
    statsData.traffic_sent_bytes = (statsData.traffic_sent_bytes || 0) + statsBuffer.traffic;
    const today = new Date().toISOString().split('T')[0];
    if (!statsData.unique_ips) statsData.unique_ips = {};
    if (!statsData.unique_ips[today]) statsData.unique_ips[today] = [];
    statsBuffer.ips.forEach(ip => { if (!statsData.unique_ips[today].includes(ip)) statsData.unique_ips[today].push(ip); });
    if (!statsData.image_download_counts) statsData.image_download_counts = {};
    for (const imgId in statsBuffer.imgDownloads) {
        if (!statsData.image_download_counts[imgId]) statsData.image_download_counts[imgId] = 0;
        statsData.image_download_counts[imgId] += statsBuffer.imgDownloads[imgId];
    }
    try {
        await fs.writeFile(analyticsPath, JSON.stringify(statsData, null, 2));
        statsBuffer = { views: 0, downloads: 0, traffic: 0, ips: new Set(), imgDownloads: {} };
    } catch (error) { console.error("Failed to flush stats to disk:", error); }
};

// --- Middleware & Helpers ---
app.use(express.json());
app.use(express.urlencoded({ extended: true }));
app.use(cookieParser());

const statsLogger = (req, res, next) => {
    const extension = path.extname(req.path).toLowerCase();
    const isAsset = ['.css', '.js', '.png', '.jpg', '.jpeg', '.gif', '.svg', '.ico'].includes(extension);
    if (!req.path.startsWith('/admin') && !req.path.startsWith('/api') && !req.path.startsWith('/download') && !isAsset) {
        statsBuffer.views++;
        statsBuffer.ips.add(req.ip);
    }
    next();
};

const readDB = async (filePath) => { try { const data = await fs.readFile(filePath, 'utf-8'); return data.trim() === '' ? [] : JSON.parse(data); } catch { return []; } };
const writeDB = async (filePath, data) => { try { await fs.writeFile(filePath, JSON.stringify(data, null, 2)); } catch (error) { console.error(`写入DB时出错: ${filePath}`, error); } };
const authMiddleware = (isApi) => (req, res, next) => {
    const token = req.cookies[AUTH_TOKEN_NAME];
    if (!token) { return isApi ? res.status(401).json({ message: '认证失败' }) : res.redirect('/login.html'); }
    try { jwt.verify(token, JWT_SECRET); next(); } 
    catch (err) { return isApi ? res.status(401).json({ message: '认证令牌无效' }) : res.redirect('/login.html'); }
};
const requirePageAuth = authMiddleware(false);
const requireApiAuth = authMiddleware(true);

// --- Auth Routes ---
app.post('/api/login', (req, res) => {
    const { username, password } = req.body;
    if (username === ADMIN_USERNAME && password === ADMIN_PASSWORD) {
        if (TWO_FACTOR_ENABLED) {
            const tempToken = jwt.sign({ username, stage: '2fa' }, JWT_SECRET, { expiresIn: '5m' });
            res.cookie(TEMP_TOKEN_NAME, tempToken, { httpOnly: true, secure: process.env.NODE_ENV === 'production', maxAge: 300000 });
            res.redirect('/2fa.html');
        } else {
            const token = jwt.sign({ username }, JWT_SECRET, { expiresIn: '1d' });
            res.cookie(AUTH_TOKEN_NAME, token, { httpOnly: true, secure: process.env.NODE_ENV === 'production', maxAge: 86400000 });
            res.redirect('/admin.html');
        }
    } else { res.redirect('/login.html?error=1'); }
});
app.post('/api/verify-2fa', (req, res) => {
    const tempToken = req.cookies[TEMP_TOKEN_NAME];
    const { code } = req.body;
    if (!tempToken) return res.redirect('/login.html?error=2');
    try {
        const decoded = jwt.verify(tempToken, JWT_SECRET);
        if (decoded.stage !== '2fa' || !authenticator.verify({ token: code, secret: TWO_FACTOR_SECRET })) {
            return res.redirect('/2fa.html?error=1');
        }
        res.clearCookie(TEMP_TOKEN_NAME);
        const token = jwt.sign({ username: decoded.username }, JWT_SECRET, { expiresIn: '1d' });
        res.cookie(AUTH_TOKEN_NAME, token, { httpOnly: true, secure: process.env.NODE_ENV === 'production', maxAge: 86400000 });
        res.redirect('/admin.html');
    } catch (err) { res.redirect('/login.html?error=2'); }
});
app.get('/api/logout', (req, res) => { res.clearCookie(AUTH_TOKEN_NAME); res.clearCookie(TEMP_TOKEN_NAME); res.redirect('/login.html'); });

// --- Admin Page Routes ---
app.get('/admin.html', requirePageAuth, (req, res) => res.sendFile(path.join(__dirname, 'public', 'admin.html')));
app.get('/admin', requirePageAuth, (req, res) => res.redirect('/admin.html'));
app.use('/2fa.html', (req, res, next) => { req.cookies[TEMP_TOKEN_NAME] ? next() : res.redirect('/login.html'); });

// --- Public API & Resource Routes ---
app.use(statsLogger);

app.get('/api/images', async (req, res) => {
    let images = (await readDB(dbPath)).filter(img => !img.isDeleted);
    const { category, search, page = 1, limit = 12 } = req.query;
    if (search) {
        const searchTerm = search.toLowerCase();
        images = images.filter(img => (img.originalFilename && img.originalFilename.toLowerCase().includes(searchTerm)) || (img.description && img.description.toLowerCase().includes(searchTerm)));
    }
    if (category && category !== 'all' && category !== 'random') images = images.filter(img => img.category === category);
    else if (category === 'random') images.sort(() => 0.5 - Math.random());
    else images.sort((a, b) => new Date(b.uploadedAt) - new Date(a.uploadedAt));
    const pageNum = parseInt(page), limitNum = parseInt(limit);
    const startIndex = (pageNum - 1) * limitNum, endIndex = pageNum * limitNum;
    res.json({ images: images.slice(startIndex, endIndex), page: pageNum, totalPages: Math.ceil(images.length / limitNum), totalImages: images.length, hasMore: endIndex < images.length });
});
app.get('/api/public/categories', async (req, res) => {
    const allDefinedCategories = await readDB(categoriesPath);
    const images = (await readDB(dbPath)).filter(img => !img.isDeleted);
    const categoriesInUse = new Set(images.map(img => img.category));
    res.json(allDefinedCategories.filter(cat => categoriesInUse.has(cat)).sort((a,b) => a === UNCATEGORIZED ? -1 : b === UNCATEGORIZED ? 1 : a.localeCompare(b, 'zh-CN')));
});
app.get('/api/categories', async (req, res) => {
    const categories = await readDB(categoriesPath);
    res.json(categories.sort((a,b) => a === UNCATEGORIZED ? -1 : b === UNCATEGORIZED ? 1 : a.localeCompare(b, 'zh-CN')));
});
app.get('/image-proxy/:filename', async (req, res) => {
    const { filename } = req.params; const { w, h, format } = req.query; const width = w ? parseInt(w) : null; const height = h ? parseInt(h) : null;
    const originalPath = path.join(uploadsDir, filename); const ext = path.extname(filename); const name = path.basename(filename, ext);
    const browserAcceptsWebP = req.headers.accept && req.headers.accept.includes('image/webp');
    const targetFormat = (format === 'webp' || browserAcceptsWebP) ? 'webp' : 'jpeg'; const mimeType = `image/${targetFormat}`;
    const cacheFilename = `${name}_w${width||'auto'}_h${height||'auto'}.${targetFormat}`; const cachePath = path.join(cacheDir, cacheFilename);
    try { await fs.access(cachePath); res.sendFile(cachePath); } catch (error) {
        try {
            await fs.access(originalPath);
            const transformer = sharp(originalPath).resize(width, height, { fit: 'inside', withoutEnlargement: true });
            const processedImageBuffer = await transformer[targetFormat]({ quality: 80 }).toBuffer();
            await fs.writeFile(cachePath, processedImageBuffer); res.type(mimeType).send(processedImageBuffer);
        } catch (procError) { res.status(404).send('Image not found.'); }
    }
});
app.get('/download/:id', async (req, res) => {
    try {
        const images = await readDB(dbPath);
        const image = images.find(img => img.id === req.params.id);
        if (!image || image.isDeleted) return res.status(404).send("Image not found.");
        statsBuffer.downloads++;
        statsBuffer.traffic += image.size || 0;
        statsBuffer.imgDownloads[image.id] = (statsBuffer.imgDownloads[image.id] || 0) + 1;
        res.download(path.join(uploadsDir, image.filename), image.originalFilename);
    } catch { res.status(500).send("Server error."); }
});

// --- Admin API Routes ---
const apiAdminRouter = express.Router();
apiAdminRouter.use(requireApiAuth);
const upload = multer({ storage: multer.diskStorage({ destination: uploadsDir, filename: (req, file, cb) => cb(null, `${uuidv4()}${path.extname(file.originalname)}`) }) });

apiAdminRouter.post('/upload', upload.array('images'), async (req, res) => {
    if (!req.files || req.files.length === 0) return res.status(400).json({ message: '没有选择文件。' });
    try {
        const images = await readDB(dbPath);
        for (const file of req.files) {
            const metadata = await sharp(file.path).metadata();
            images.unshift({
                id: uuidv4(), src: `/uploads/${file.filename}`, category: req.body.category || UNCATEGORIZED,
                description: req.body.description || '', originalFilename: file.originalname, filename: file.filename,
                size: file.size, uploadedAt: new Date().toISOString(), width: metadata.width, height: metadata.height,
                isDeleted: false, deletedAt: null
            });
        }
        await writeDB(dbPath, images);
        res.status(200).json({ message: '上传成功' });
    } catch (error) { res.status(500).json({message: '上传失败，处理图片信息时出错。'}) }
});
apiAdminRouter.delete('/images/:id', async (req, res) => {
    let images = await readDB(dbPath);
    const imageIndex = images.findIndex(img => img.id === req.params.id);
    if (imageIndex > -1) {
        images[imageIndex].isDeleted = true; images[imageIndex].deletedAt = new Date().toISOString();
        await writeDB(dbPath, images); res.json({ message: '图片已移至回收站' });
    } else { res.status(404).json({ message: '图片未找到' }); }
});
apiAdminRouter.put('/images/:id', async (req, res) => {
    let images = await readDB(dbPath);
    const { category, description, originalFilename } = req.body;
    const imageIndex = images.findIndex(img => img.id === req.params.id);
    if (imageIndex > -1) {
        const imageToUpdate = { ...images[imageIndex], category: category || images[imageIndex].category, description: description !== undefined ? description : images[imageIndex].description, originalFilename: originalFilename || images[imageIndex].originalFilename };
        images[imageIndex] = imageToUpdate;
        await writeDB(dbPath, images);
        res.json({ message: '更新成功', image: imageToUpdate });
    } else { res.status(404).json({ message: '图片未找到' }); }
});
apiAdminRouter.get('/recyclebin', async (req, res) => res.json({ images: (await readDB(dbPath)).filter(img => img.isDeleted).sort((a,b) => new Date(b.deletedAt) - new Date(a.deletedAt)) }));
apiAdminRouter.post('/recyclebin/restore/:id', async (req, res) => {
    let images = await readDB(dbPath);
    const imageIndex = images.findIndex(img => img.id === req.params.id);
    if (imageIndex > -1) {
        images[imageIndex].isDeleted = false; images[imageIndex].deletedAt = null;
        await writeDB(dbPath, images); res.json({ message: '图片已从回收站恢复' });
    } else { res.status(404).json({ message: '图片未找到' }); }
});
apiAdminRouter.delete('/recyclebin/permanent/:id', async (req, res) => {
    let images = await readDB(dbPath);
    const imageToDelete = images.find(img => img.id === req.params.id);
    if (imageToDelete) {
        try { await fs.unlink(path.join(uploadsDir, imageToDelete.filename)); } catch (error) { console.error(`删除物理文件失败: ${error.message}`); }
        await writeDB(dbPath, images.filter(img => img.id !== req.params.id));
        res.json({ message: '图片已永久删除' });
    } else { res.status(404).json({ message: '图片未找到' }); }
});
apiAdminRouter.post('/categories', async (req, res) => {
    const { name } = req.body; if (!name) return res.status(400).json({ message: '分类名称不能为空。' });
    let categories = await readDB(categoriesPath); if (categories.includes(name)) return res.status(409).json({ message: '该分类已存在。' });
    categories.push(name); await writeDB(categoriesPath, categories); res.status(201).json({ message: '分类创建成功', category: name });
});
apiAdminRouter.delete('/categories', async (req, res) => {
    const { name } = req.body; if (!name || name === UNCATEGORIZED) return res.status(400).json({ message: '无效的分类或“未分类”无法删除。' });
    let categories = await readDB(categoriesPath); if (!categories.includes(name)) return res.status(404).json({ message: '该分类不存在。' });
    const updatedCategories = categories.filter(cat => cat !== name); await writeDB(categoriesPath, updatedCategories);
    let images = await readDB(dbPath); images.forEach(img => { if (img.category === name) img.category = UNCATEGORIZED; });
    await writeDB(dbPath, images); res.status(200).json({ message: `分类 '${name}' 已删除。` });
});
apiAdminRouter.put('/categories', async (req, res) => {
    const { oldName, newName } = req.body; if (!oldName || !newName || oldName === newName || oldName === UNCATEGORIZED) return res.status(400).json({ message: '无效的分类名称。' });
    let categories = await readDB(categoriesPath); if (!categories.includes(oldName)) return res.status(404).json({ message: '旧分类不存在。' });
    if (categories.includes(newName)) return res.status(409).json({ message: '新的分类名称已存在。' });
    const updatedCategories = categories.map(cat => (cat === oldName ? newName : cat)); await writeDB(categoriesPath, updatedCategories);
    let images = await readDB(dbPath); images.forEach(img => { if (img.category === oldName) img.category = newName; });
    await writeDB(dbPath, images); res.status(200).json({ message: `分类 '${oldName}' 已重命名为 '${newName}'。` });
});
apiAdminRouter.get('/stats', async (req, res) => {
    const images = await readDB(dbPath);
    const uptimeMs = new Date() - SERVER_START_TIME;
    const days = Math.floor(uptimeMs / 86400000); const hours = Math.floor((uptimeMs % 86400000) / 3600000);
    const currentTotalViews = (statsData.total_views || 0) + statsBuffer.views;
    const currentTotalDownloads = (statsData.total_downloads || 0) + statsBuffer.downloads;
    const currentTotalTraffic = (statsData.traffic_sent_bytes || 0) + statsBuffer.traffic;
    const today = new Date().toISOString().split('T')[0];
    const uniqueIpsToday = new Set([...((statsData.unique_ips || {})[today] || []), ...statsBuffer.ips]).size;
    const combinedDownloadCounts = {...(statsData.image_download_counts || {})};
    for (const imgId in statsBuffer.imgDownloads) { combinedDownloadCounts[imgId] = (combinedDownloadCounts[imgId] || 0) + statsBuffer.imgDownloads[imgId]; }
    const popularDownloads = Object.entries(combinedDownloadCounts).sort(([,a],[,b]) => b - a).slice(0, 5)
        .map(([id, count]) => {
            const image = images.find(img => img.id === id);
            return { id, thumbnail: image ? `/image-proxy/${image.filename}?w=100` : null, originalFilename: image ? image.originalFilename : '已删除的图片', count };
        });
    res.json({ uptime: { days, hours }, total_views: currentTotalViews, total_downloads: currentTotalDownloads, traffic_sent_bytes: currentTotalTraffic, unique_ips_today: uniqueIpsToday, popular_downloads: popularDownloads });
});

app.use('/api/admin', apiAdminRouter);
app.use(express.static(path.join(__dirname, 'public')));

// --- Server Start ---
(async () => {
    await fs.mkdir(path.join(__dirname, 'data'), { recursive: true }).catch(console.error);
    if (!process.env.JWT_SECRET) { console.error(`错误: JWT_SECRET 未设置。`); process.exit(1); }
    if (process.env.TWO_FACTOR_ENABLED === 'true' && !process.env.TWO_FACTOR_SECRET) { console.error(`错误: 2FA已启用但密钥未设置。`); process.exit(1); }
    await loadStats();
    setInterval(flushStatsToDisk, FLUSH_INTERVAL);
    app.listen(PORT, () => console.log(`服务器正在 http://localhost:${PORT} 运行`));
    process.on('SIGINT', async () => { console.log("\n优雅关闭中，正在将统计数据写入磁盘..."); await flushStatsToDisk(); process.exit(0); });
})();
EOF

    echo "--> 正在生成主画廊 public/index.html..."
cat << 'EOF' > public/index.html
<!DOCTYPE html><html lang="zh-CN"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0"><title>图片画廊</title><link rel="preconnect" href="https://fonts.googleapis.com"><link rel="preconnect" href="https://fonts.gstatic.com" crossorigin><link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;700&family=Noto+Sans+SC:wght@400;500;700&display=swap" rel="stylesheet"><script src="https://cdn.tailwindcss.com"></script><style>:root{--bg-color:#f0fdf4;--text-color:#14532d;--header-bg-scrolled:rgba(240,253,244,.85);--filter-btn-color:#166534;--filter-btn-hover-bg:#dcfce7;--filter-btn-active-bg:#22c55e;--filter-btn-active-border:#16a34a;--grid-item-bg:#e4e4e7;--search-bg:#fff;--search-placeholder-color:#9ca3af;--divider-color:#dcfce7}body.dark{--bg-color:#111827;--text-color:#a7f3d0;--header-bg-scrolled:rgba(17,24,39,.85);--filter-btn-color:#a7f3d0;--filter-btn-hover-bg:#1f2937;--filter-btn-active-bg:#16a34a;--filter-btn-active-border:#15803d;--grid-item-bg:#374151;--search-bg:#1f2937;--search-placeholder-color:#6b7280;--divider-color:#166534}body{font-family:'Inter','Noto Sans SC',sans-serif;background-color:var(--bg-color);color:var(--text-color)}body.overflow-hidden{overflow:hidden}.header-sticky{padding-top:1rem;padding-bottom:1rem;background-color:rgba(240,253,244,0);position:sticky;top:0;z-index:40;box-shadow:0 1px 2px 0 rgba(0,0,0,.05);transition:padding .3s ease-in-out,background-color .3s ease-in-out}.header-sticky #header-top{transition:opacity .3s ease-in-out,height .3s ease-in-out,margin-bottom .3s ease-in-out}.header-sticky.is-scrolled{padding-top:.5rem;padding-bottom:.5rem;background-color:var(--header-bg-scrolled);-webkit-backdrop-filter:blur(8px);backdrop-filter:blur(8px)}.header-sticky.is-scrolled #header-top{opacity:0;height:0;margin-bottom:0;pointer-events:none;overflow:hidden}#search-overlay{opacity:0;visibility:hidden;transition:opacity .3s ease,visibility 0s .3s}#search-overlay.active{opacity:1;visibility:visible;transition:opacity .3s ease,visibility 0s 0s}#search-box{transform:scale(.95);opacity:0;transition:transform .3s ease,opacity .3s ease}#search-overlay.active #search-box{transform:scale(1);opacity:1}.grid-gallery{display:grid;grid-template-columns:repeat(auto-fill,minmax(150px,1fr));grid-auto-rows:10px;gap:.75rem}@media (min-width:768px){.grid-gallery{grid-template-columns:repeat(auto-fill,minmax(200px,1fr));gap:1rem}}@media (min-width:1024px){.grid-gallery{grid-template-columns:repeat(auto-fill,minmax(240px,1fr))}}.grid-item{position:relative;border-radius:.5rem;overflow:hidden;background-color:var(--grid-item-bg);box-shadow:0 4px 6px -1px rgba(0,0,0,.1),0 2px 4px -2px rgba(0,0,0,.1);opacity:0;transform:translateY(20px);transition:opacity .5s ease-out,transform .5s ease-out,box-shadow .3s ease}.grid-item-wide{grid-column:span 2}@media (max-width:400px){.grid-item-wide{grid-column:span 1}}.grid-item.is-visible{opacity:1;transform:translateY(0)}.grid-item img{cursor:pointer;width:100%;height:100%;-o-object-fit:cover;object-fit:cover;display:block;transition:transform .4s ease}.grid-item:hover img{transform:scale(1.05)}.filter-btn{padding:.5rem 1rem;border-radius:9999px;font-weight:500;transition:all .2s ease;border:1px solid transparent;cursor:pointer;background-color:transparent;color:var(--filter-btn-color)}.filter-btn:hover{background-color:var(--filter-btn-hover-bg)}.filter-btn.active{background-color:var(--filter-btn-active-bg);color:#fff;border-color:var(--filter-btn-active-border)}.lightbox{position:fixed;top:0;left:0;width:100%;height:100%;background-color:rgba(0,0,0,.9);display:flex;justify-content:center;align-items:center;z-index:1000;opacity:0;visibility:hidden;transition:opacity .3s ease}.lightbox.active{opacity:1;visibility:visible}.lightbox-image{max-width:85%;max-height:85%;display:block;-o-object-fit:contain;object-fit:contain}.lightbox-btn{position:absolute;top:50%;transform:translateY(-50%);background-color:rgba(255,255,255,.1);color:#fff;border:none;font-size:2.5rem;cursor:pointer;padding:.5rem 1rem;border-radius:.5rem;transition:background-color .2s}.lightbox-btn:hover{background-color:rgba(255,255,255,.2)}.lb-prev{left:1rem}.lb-next{right:1rem}.lb-close{top:1rem;right:1rem;font-size:2rem}.lb-counter{position:absolute;top:1.5rem;left:50%;transform:translateX(-50%);color:#fff;font-size:1rem;background-color:rgba(0,0,0,.3);padding:.25rem .75rem;border-radius:9999px}.lb-download{position:absolute;bottom:1rem;right:1rem;background-color:#22c55e;color:#fff;border:none;padding:.5rem 1rem;border-radius:.5rem;cursor:pointer;transition:background-color .2s;font-size:1rem;text-decoration:none}.back-to-top{position:fixed;bottom:2rem;right:2rem;background-color:#22c55e;color:#fff;width:3rem;height:3rem;border-radius:9999px;display:flex;align-items:center;justify-content:center;box-shadow:0 4px 8px rgba(0,0,0,.2);cursor:pointer;opacity:0;visibility:hidden;transform:translateY(20px);transition:all .3s ease}.back-to-top.visible{opacity:1;visibility:visible;transform:translateY(0)}</style></head><body class="antialiased flex flex-col min-h-screen"><header class="text-center header-sticky"><div id="header-top" class="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 flex items-center justify-between h-auto md:h-14 mb-4"><div class="w-1/3"></div><h1 class="text-4xl md:text-5xl font-bold w-1/3 whitespace-nowrap text-center">图片画廊</h1><div class="w-1/3 flex items-center justify-end gap-1"><button id="search-toggle-btn" title="搜索" class="p-2 rounded-full text-[var(--text-color)] hover:bg-gray-500/10"><svg class="w-6 h-6" xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor"><path stroke-linecap="round" stroke-linejoin="round" d="m21 21-5.197-5.197m0 0A7.5 7.5 0 1 0 5.196 5.196a7.5 7.5 0 0 0 10.607 10.607Z"/></svg></button><button id="theme-toggle" title="切换主题" class="p-2 rounded-full text-[var(--text-color)] hover:bg-gray-500/10"><svg id="theme-icon-sun" class="w-6 h-6" fill="none" viewBox="0 0 24 24" stroke="currentColor"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 3v1m0 16v1m9-9h-1M4 12H3m15.364 6.364l-.707-.707M6.343 6.343l-.707-.707m12.728 0l-.707.707M6.343 17.657l-.707.707M16 12a4 4 0 11-8 0 4 4 0 018 0z"/></svg><svg id="theme-icon-moon" class="w-6 h-6 hidden" fill="none" viewBox="0 0 24 24" stroke="currentColor"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M20.354 15.354A9 9 0 018.646 3.646 9.003 9.003 0 0012 21a9.003 9.003 0 008.354-5.646z"/></svg></button></div></div><div id="filter-buttons" class="flex justify-center flex-wrap gap-2 px-4"><button class="filter-btn active" data-filter="all">全部</button><button class="filter-btn" data-filter="random">随机</button></div></header><div class="border-b-2" style="border-color:var(--divider-color)"></div><main class="container mx-auto px-4 sm:px-6 py-8 md:py-10 flex-grow"><div id="gallery-container" class="max-w-7xl mx-auto grid-gallery"></div><div id="loader" class="text-center py-8 hidden">正在加载更多...</div></main><footer class="text-center py-8 border-t" style="border-color:var(--divider-color)"><p>© 2025 图片画廊</p></footer><div id="search-overlay" class="fixed inset-0 z-50 flex items-start justify-center pt-24 md:pt-32 p-4 bg-black/30"><div id="search-box" class="w-full max-w-lg relative flex items-center gap-2"><div class="absolute top-1/2 left-5 -translate-y-1/2 text-gray-400"><svg class="w-6 h-6" xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="2" stroke="currentColor"><path stroke-linecap="round" stroke-linejoin="round" d="m21 21-5.197-5.197m0 0A7.5 7.5 0 1 0 5.196 5.196a7.5 7.5 0 0 0 10.607 10.607Z"/></svg></div><input type="search" id="search-input" placeholder="输入关键词，按 Enter 或点击按钮..." class="w-full py-4 pl-14 pr-5 text-lg rounded-lg border-0 shadow-2xl focus:ring-2 focus:ring-green-500" style="background-color:var(--search-bg);color:var(--text-color)"><button id="search-exec-btn" class="bg-green-600 hover:bg-green-700 text-white font-bold py-4 px-5 rounded-lg transition-colors absolute right-0 top-0 h-full"><svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="2" stroke="currentColor" class="w-6 h-6"><path stroke-linecap="round" stroke-linejoin="round" d="m21 21-5.197-5.197m0 0A7.5 7.5 0 1 0 5.196 5.196a7.5 7.5 0 0 0 10.607 10.607Z"/></svg></button></div></div><div class="lightbox"><span class="lb-counter"></span><button class="lightbox-btn lb-close">&times;</button><button class="lightbox-btn lb-prev">&lsaquo;</button><img class="lightbox-image" alt=""><button class="lightbox-btn lb-next">&rsaquo;</button><a href="#" id="lightbox-download-link" download class="lb-download">下载</a></div><a class="back-to-top" title="返回顶部"><svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 19V5M5 12l7-7 7 7"/></svg></a><script>document.addEventListener("DOMContentLoaded",function(){const e=document.body,t=document.getElementById("gallery-container"),n=document.getElementById("loader"),o=document.getElementById("filter-buttons"),a=document.querySelector(".header-sticky");let i=[],l="all",r="",s=1,c=!1,d=!0,u,m;const g=document.getElementById("search-toggle-btn"),h=document.getElementById("theme-toggle"),p=document.getElementById("theme-icon-sun"),f=document.getElementById("theme-icon-moon"),y=document.getElementById("search-overlay"),v=document.getElementById("search-input"),b=document.getElementById("search-exec-btn"),E=()=>{y.classList.add("active"),e.classList.add("overflow-hidden"),setTimeout(()=>v.focus(),50)},w=()=>{y.classList.remove("active"),e.classList.remove("overflow-hidden")};g.addEventListener("click",E),y.addEventListener("click",e=>{e.target===y&&w()}),document.addEventListener("keydown",e=>{"Escape"===e.key&&y.classList.contains("active")&&w()});const L=()=>{const e=v.value.trim();r=e,document.querySelectorAll(".filter-btn").forEach(e=>e.classList.remove("active")),o.querySelector('[data-filter="all"]').classList.add("active"),l="all",w(),S(),B()};v.addEventListener("keydown",e=>{"Enter"===e.key&&L()}),b.addEventListener("click",L);const k=t=>{t==="dark"?(e.classList.add("dark"),p.classList.add("hidden"),f.classList.remove("hidden")):(e.classList.remove("dark"),p.classList.remove("hidden"),f.classList.add("hidden"))};h.addEventListener("click",()=>{const e="dark"===body.classList.contains("dark")?"light":"dark";localStorage.setItem("theme",e),k(e)}),k(localStorage.getItem("theme")||(window.matchMedia("(prefers-color-scheme: dark)").matches?"dark":"light"));const H=async e=>{const t=await fetch(e);if(!t.ok)throw new Error(`HTTP error! status: ${t.status}`);return t.json()},S=()=>{t.innerHTML="",i=[],s=1,d=!0,window.scrollTo(0,0)},B=async()=>{if(c||!d)return;c=!0,n.classList.remove("hidden");try{const e=`/api/images?page=${s}&limit=12&category=${l}&search=${encodeURIComponent(r)}`,o=await H(e);n.classList.add("hidden"),o.images&&o.images.length>0?(A(o.images),i.push(...o.images),s++,d=o.hasMore):d=!1,i.length||(n.textContent="没有找到符合条件的图片。")}catch(e){console.error("获取图片数据失败:",e),n.textContent="加载失败，请刷新页面。"}finally{c=!1,d||n.classList.add("hidden")}};const A=e=>{e.forEach(e=>{const n=document.createElement("div");n.className="grid-item",n.dataset.id=e.id;const o=document.createElement("img");o.src="data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7",o.dataset.src=`/image-proxy/${e.filename}?w=400`,o.alt=e.description||e.originalFilename,o.onerror=()=>n.remove(),n.appendChild(o),t.appendChild(n),C.observe(n)})},C=new IntersectionObserver((e,t)=>{e.forEach(e=>{if(e.isIntersecting){const n=e.target,o=n.querySelector("img");o.src=o.dataset.src,o.onload=()=>{n.style.backgroundColor="transparent",n.classList.add("is-visible"),N(n)},t.unobserve(n)}})},{rootMargin:"0px 0px 200px 0px"}),N=e=>{const t=e.querySelector("img");if(!t||!t.complete||0===t.naturalHeight)return;const n=i.find(t=>t.id===e.dataset.id);if(!n)return;const o=n.width/n.height;o>1.2?e.classList.add("grid-item-wide"):e.classList.remove("grid-item-wide");const a=e.clientWidth;a>0&&e.style.setProperty("grid-row-end",`span ${Math.ceil((a/o+16)/(10+16))}`)},q=()=>{t.querySelectorAll(".grid-item.is-visible").forEach(N)};window.addEventListener("resize",()=>{clearTimeout(u),u=setTimeout(q,200)});const D=async()=>{try{const e=await H("/api/public/categories");o.querySelectorAll(".dynamic-filter").forEach(e=>e.remove()),e.forEach(e=>{const t=document.createElement("button");t.className="filter-btn dynamic-filter",t.dataset.filter=e,t.textContent=e,o.appendChild(t)})}catch(e){console.error("无法加载分类按钮:",e)}};o.addEventListener("click",e=>{const t=e.target.closest(".filter-btn");t&&(l=t.dataset.filter,r="",v.value="",document.querySelectorAll(".filter-btn").forEach(e=>e.classList.remove("active")),t.classList.add("active"),S(),B())});const T=document.querySelector(".lightbox"),I=T.querySelector(".lightbox-image"),x=T.querySelector(".lb-counter"),O=document.getElementById("lightbox-download-link");let M=0;t.addEventListener("click",t=>{const n=t.target.closest(".grid-item");n&&(m=document.activeElement,(M=i.findIndex(e=>e.id===n.dataset.id))!==-1&&(z(),T.classList.add("active"),e.classList.add("overflow-hidden")))});const z=()=>{const e=i[M];e&&(I.src=e.src,I.alt=e.description,x.textContent=`${M+1} / ${i.length}`,O.href=`/download/${e.id}`,O.download=e.originalFilename)},P=()=>{M=(M-1+i.length)%i.length,z()},R=()=>{M=(M+1)%i.length,z()},U=()=>{T.classList.remove("active"),e.classList.remove("overflow-hidden"),m&&m.focus()};T.addEventListener("click",e=>{const t=e.target;t.matches(".lb-next")?R():t.matches(".lb-prev")?P():(t.matches(".lb-close")||t===T)&&U()}),document.addEventListener("keydown",e=>{T.classList.contains("active")&&("ArrowLeft"===e.key?P():"ArrowRight"===e.key?R():"Escape"===e.key&&U())});const V=document.querySelector(".back-to-top");let W=!1;V.addEventListener("click",()=>window.scrollTo({top:0,behavior:"smooth"}));const X=()=>{const e=window.scrollY;e>300?V.classList.add("visible"):V.classList.remove("visible"),e>10?a.classList.add("is-scrolled"):a.classList.remove("is-scrolled"),window.innerHeight+window.scrollY>=document.body.offsetHeight-500&&B()};window.addEventListener("scroll",()=>{W||(window.requestAnimationFrame(()=>{X(),W=!1}),W=!0)}),(async function(){await D(),await B()})()});</script></body></html>
EOF

    echo "--> 正在生成后台登录页 public/login.html..."
cat << 'EOF' > public/login.html
<!DOCTYPE html><html lang="zh-CN"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0"><title>后台登录 - 图片画廊</title><script src="https://cdn.tailwindcss.com"></script><style> body { background-color: #f0fdf4; } </style></head><body class="antialiased text-green-900"><div class="min-h-screen flex items-center justify-center"><div class="max-w-md w-full bg-white p-8 rounded-lg shadow-lg"><h1 class="text-3xl font-bold text-center text-green-900 mb-6">后台管理登录</h1><div id="error-message" class="hidden bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded relative mb-4" role="alert"><strong class="font-bold">登录失败！</strong><span id="error-text" class="block sm:inline">用户名或密码不正确。</span></div><form action="/api/login" method="POST"><div class="mb-4"><label for="username" class="block text-green-800 text-sm font-bold mb-2">用户名</label><input type="text" id="username" name="username" required class="shadow appearance-none border rounded w-full py-2 px-3 text-gray-700 leading-tight focus:outline-none focus:ring-2 focus:ring-green-500"></div><div class="mb-6"><label for="password" class="block text-green-800 text-sm font-bold mb-2">密码</label><input type="password" id="password" name="password" required class="shadow appearance-none border rounded w-full py-2 px-3 text-gray-700 mb-3 leading-tight focus:outline-none focus:ring-2 focus:ring-green-500"></div><div class="flex items-center justify-between"><button type="submit" class="w-full bg-green-600 hover:bg-green-700 text-white font-bold py-2 px-4 rounded-lg focus:outline-none focus:shadow-outline transition-colors"> 登 录 </button></div></form></div></div><script>const urlParams=new URLSearchParams(window.location.search);if(urlParams.has("error")){const err=urlParams.get("error");const errTxt=document.getElementById("error-text");if(err==="1"){errTxt.textContent="用户名或密码不正确。"}else if(err==="2"){errTxt.textContent="会话已过期，请重新登录。"}document.getElementById("error-message").classList.remove("hidden")}</script></body></html>
EOF

    echo "--> 正在生成新的 public/2fa.html..."
cat << 'EOF' > public/2fa.html
<!DOCTYPE html><html lang="zh-CN"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0"><title>2FA 验证 - 图片画廊</title><script src="https://cdn.tailwindcss.com"></script><style>body{background-color:#f0fdf4}</style></head><body class="antialiased text-green-900"><div class="min-h-screen flex items-center justify-center"><div class="max-w-sm w-full bg-white p-8 rounded-lg shadow-lg text-center"><h1 class="text-2xl font-bold text-center text-green-900 mb-2">双因素认证</h1><p class="text-slate-600 mb-6">请打开您的 Authenticator 应用，输入6位动态验证码。</p><div id="error-message" class="hidden bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded relative mb-4" role="alert"><strong>验证失败！</strong><span class="block sm:inline">验证码不正确，请重试。</span></div><form action="/api/verify-2fa" method="POST" id="2fa-form"><div class="mb-4"><label for="code" class="block text-green-800 text-sm font-bold mb-2 sr-only">验证码</label><input type="text" id="code" name="code" required inputmode="numeric" pattern="[0-9]{6}" maxlength="6" class="w-full text-center tracking-[1em] text-2xl font-mono bg-green-50 border-2 border-green-200 rounded py-2 px-3 leading-tight focus:outline-none focus:ring-2 focus:ring-green-500"></div><div class="flex items-center justify-between"><button type="submit" class="w-full bg-green-600 hover:bg-green-700 text-white font-bold py-2 px-4 rounded-lg focus:outline-none focus:shadow-outline transition-colors"> 验 证 </button></div></form></div></div><script>const urlParams=new URLSearchParams(window.location.search);urlParams.has("error")&&document.getElementById("error-message").classList.remove("hidden");document.getElementById("code").focus();</script></body></html>
EOF

    echo "--> 正在生成后台管理页 public/admin.html..."
cat << 'EOF' > public/admin.html
<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0"><title>后台管理 - 图片画廊</title>
    <script src="https://cdn.tailwindcss.com"></script>
    <style>
        body { background-color: #f8fafc; } .modal, .toast, .lightbox { display: none; } .modal.active, .lightbox.active { display: flex; } body.lightbox-open { overflow: hidden; }
        .main-nav-btn { transition: all 0.2s ease-in-out; }
        .main-nav-btn.active { color: #166534; border-color: #16a34a; background-color: #f0fdf4; }
        .stat-card { background-color: white; border-radius: 0.75rem; box-shadow: 0 1px 3px 0 rgba(0,0,0,0.1), 0 1px 2px -1px rgba(0,0,0,0.1); padding: 1.5rem; display: flex; flex-direction: column; }
        .category-item.active { background-color: #dcfce7; font-weight: bold; } .toast { position: fixed; top: 1.5rem; right: 1.5rem; z-index: 9999; transform: translateX(120%); transition: transform 0.3s ease-in-out; } .toast.show { transform: translateX(0); }
        .tab-btn.active{ border-color: #16a34a; background-color: #dcfce7; color: #166534; font-weight: 600;}
        .file-preview-item.upload-success { background-color: #f0fdf4; } .file-preview-item.upload-error { background-color: #fef2f2; }
    </style>
</head>
<body class="antialiased text-slate-800">
    <header class="bg-white shadow-md p-4 flex justify-between items-center sticky top-0 z-20"><h1 class="text-2xl font-bold text-slate-900">后台管理系统</h1><div class="flex items-center gap-2"><a href="/" target="_blank" title="查看前台" class="flex items-center gap-2 bg-white border border-gray-300 text-gray-700 font-semibold py-2 px-4 rounded-lg hover:bg-gray-50 transition-colors"><svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor" class="w-5 h-5"><path stroke-linecap="round" stroke-linejoin="round" d="M13.5 6H5.25A2.25 2.25 0 003 8.25v10.5A2.25 2.25 0 005.25 21h10.5A2.25 2.25 0 0018 18.75V10.5m-4.5 0V6.375c0-.621.504-1.125 1.125-1.125h1.125c.621 0 1.125.504 1.125 1.125V10.5m-4.5 0h4.5m-4.5 0a2.25 2.25 0 01-2.25-2.25V8.25c0-.621.504-1.125 1.125-1.125h1.125c.621 0 1.125.504 1.125 1.125v3.375M3 11.25h1.5m1.5 0h1.5m-1.5 0l1.5-1.5m-1.5 1.5l-1.5-1.5m9 6.75l1.5-1.5m-1.5 1.5l-1.5-1.5" /></svg><span class="hidden sm:inline">查看前台</span></a><a href="/api/logout" title="退出登录" class="flex items-center gap-2 bg-red-600 hover:bg-red-700 text-white font-bold py-2 px-4 rounded-lg transition-colors"><svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor" class="w-5 h-5"><path stroke-linecap="round" stroke-linejoin="round" d="M15.75 9V5.25A2.25 2.25 0 0013.5 3h-6a2.25 2.25 0 00-2.25 2.25v13.5A2.25 2.25 0 007.5 21h6a2.25 2.25 0 002.25-2.25V15M12 9l-3 3m0 0l3 3m-3-3h12.75" /></svg><span class="hidden sm:inline">退出登录</span></a></div></header>
    <nav class="bg-white border-b border-slate-200"><div class="container mx-auto px-4 md:px-6"><div class="flex items-center gap-4"><button id="nav-content" class="main-nav-btn py-4 px-3 text-sm font-medium border-b-2 border-transparent">内容管理</button><button id="nav-stats" class="main-nav-btn py-4 px-3 text-sm font-medium border-b-2 border-transparent">站点统计</button></div></div></nav>
    <div id="content-management-view"><main class="container mx-auto p-4 md:p-6 grid grid-cols-1 xl:grid-cols-12 gap-8"><div class="xl:col-span-4 space-y-8"><section class="bg-white p-6 rounded-lg shadow-md"><h2 class="text-xl font-semibold mb-4">上传新图片</h2><form id="upload-form" class="space-y-4"><div><label for="image-input" id="drop-zone" class="w-full flex flex-col items-center justify-center p-6 border-2 border-dashed border-gray-300 rounded-lg cursor-pointer hover:bg-gray-50"><svg class="w-10 h-10 mb-3 text-gray-400" fill="none" viewBox="0 0 20 16"><path stroke="currentColor" stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M13 13h3a3 3 0 0 0 0-6h-.025A5.56 5.56 0 0 0 16 6.5 5.5 5.5 0 0 0 5.207 5.021C5.137 5.017 5.071 5 5 5a4 4 0 0 0 0 8h2.167M10 15V6m0 0L8 8m2-2 2 2"/></svg><p class="text-sm text-gray-500"><span class="font-semibold">点击或拖拽</span>上传</p><input id="image-input" type="file" class="hidden" multiple accept="image/*"/></label></div><div id="file-preview-container" class="hidden space-y-2"><div id="upload-summary" class="text-sm font-medium text-slate-600"></div><div id="file-preview-list" class="h-48 border rounded p-2 space-y-3 overflow-auto"></div></div><div><label for="category-select" class="block text-sm font-medium mb-1">设置分类</label><div class="flex items-center space-x-2"><select id="category-select" class="w-full border rounded px-3 py-2"></select><button type="button" id="add-category-btn" class="flex-shrink-0 bg-green-500 hover:bg-green-600 text-white font-bold w-9 h-9 rounded-full flex items-center justify-center text-xl">+</button></div></div><button type="submit" id="upload-btn" class="w-full bg-green-600 hover:bg-green-700 text-white font-bold py-2 px-4 rounded-lg disabled:bg-gray-400" disabled>上传文件</button></form></section><section id="category-management-section" class="bg-white p-6 rounded-lg shadow-md"><h2 class="text-xl font-semibold mb-4">分类管理</h2><div id="category-management-list" class="space-y-2"></div></section></div><section class="bg-white p-6 rounded-lg shadow-md xl:col-span-8"><div class="flex flex-col md:flex-row justify-between items-center mb-4 gap-4"><div class="flex-grow"><div class="border-b border-gray-200"><nav class="-mb-px flex space-x-4"><button id="tab-gallery" class="tab-btn py-2 px-3 border-b-2 font-medium text-sm">画廊</button><button id="tab-recycle-bin" class="tab-btn py-2 px-3 border-b-2 font-medium text-sm">回收站</button></nav></div></div><div id="search-container" class="w-full md:w-64"><input type="search" id="search-input" placeholder="搜索..." class="w-full border rounded-full px-4 py-2 text-sm"></div></div><h2 id="image-list-header" class="text-xl font-semibold text-slate-900 mb-4"></h2><div id="image-list" class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 2xl:grid-cols-4 gap-4"></div><div id="image-loader" class="text-center py-8 text-slate-500 hidden"></div></section></main></div>
    <div id="statistics-view" class="hidden"><main class="container mx-auto p-4 md:p-6"><div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 xl:grid-cols-5 gap-6"><div class="stat-card"><p class="text-sm font-medium text-slate-500">站点已运行</p><p id="stat-uptime" class="mt-1 text-3xl font-semibold tracking-tight text-slate-900">-</p></div><div class="stat-card"><p class="text-sm font-medium text-slate-500">总浏览量 (PV)</p><p id="stat-views" class="mt-1 text-3xl font-semibold tracking-tight text-slate-900">-</p></div><div class="stat-card"><p class="text-sm font-medium text-slate-500">今日独立访客 (UV)</p><p id="stat-ips" class="mt-1 text-3xl font-semibold tracking-tight text-slate-900">-</p></div><div class="stat-card"><p class="text-sm font-medium text-slate-500">总下载次数</p><p id="stat-downloads" class="mt-1 text-3xl font-semibold tracking-tight text-slate-900">-</p></div><div class="stat-card"><p class="text-sm font-medium text-slate-500">预估总流量</p><p id="stat-traffic" class="mt-1 text-3xl font-semibold tracking-tight text-slate-900">-</p></div></div><div class="mt-8 stat-card"><h3 class="text-lg font-medium leading-6 text-slate-900">热门下载 Top 5</h3><ul id="stat-popular-downloads" class="mt-4 space-y-3"><li class="text-slate-500">正在加载...</li></ul></div></main></div>
    <div id="generic-modal" class="modal fixed inset-0 bg-black bg-opacity-50 items-center justify-center z-30 p-4"><div class="bg-white rounded-lg shadow-xl p-6 w-full max-w-sm"><h3 id="modal-title" class="text-lg font-bold mb-4"></h3><div id="modal-body" class="mb-4 text-slate-600"></div><div id="modal-footer" class="flex justify-end space-x-2"></div></div></div>
    <div id="edit-image-modal" class="modal fixed inset-0 bg-black bg-opacity-50 items-center justify-center z-30 p-4"><div class="bg-white rounded-lg shadow-xl p-6 w-full max-w-md"><h3 class="text-lg font-bold mb-4">编辑图片信息</h3><form id="edit-image-form"><input type="hidden" id="edit-id"><div class="mb-4"><label class="block text-sm font-medium mb-1">原始文件名</label><input type="text" id="edit-originalFilename" class="w-full border rounded px-3 py-2"></div><div class="mb-4"><label class="block text-sm font-medium mb-1">分类</label><select id="edit-category-select" class="w-full border rounded px-3 py-2"></select></div><div class="mb-4"><label class="block text-sm font-medium mb-1">描述</label><textarea id="edit-description" rows="3" class="w-full border rounded px-3 py-2"></textarea></div><div class="flex justify-end space-x-2 mt-6"><button type="button" class="modal-cancel-btn bg-gray-300 text-black py-2 px-4 rounded">取消</button><button type="submit" class="bg-blue-600 text-white py-2 px-4 rounded">保存</button></div></form></div></div>
    <div id="toast" class="toast max-w-xs bg-gray-800 text-white text-sm rounded-lg shadow-lg p-3"><div class="flex items-center"><div id="toast-icon" class="mr-2"></div><span id="toast-message"></span></div></div>
<script>
document.addEventListener('DOMContentLoaded',function(){const e={navContent:document.getElementById("nav-content"),navStats:document.getElementById("nav-stats"),contentView:document.getElementById("content-management-view"),statsView:document.getElementById("statistics-view"),tabGallery:document.getElementById("tab-gallery"),tabRecycleBin:document.getElementById("tab-recycle-bin"),categoryMgmtSection:document.getElementById("category-management-section"),searchContainer:document.getElementById("search-container"),imageList:document.getElementById("image-list"),imageLoader:document.getElementById("image-loader"),imageListHeader:document.getElementById("image-list-header"),searchInput:document.getElementById("search-input"),uploadForm:document.getElementById("upload-form"),uploadBtn:document.getElementById("upload-btn"),imageInput:document.getElementById("image-input"),dropZone:document.getElementById("drop-zone"),filePreviewList:document.getElementById("file-preview-list"),uploadSummary:document.getElementById("upload-summary"),categorySelect:document.getElementById("category-select"),addCategoryBtn:document.getElementById("add-category-btn"),categoryManagementList:document.getElementById("category-management-list"),genericModal:document.getElementById("generic-modal"),editImageModal:document.getElementById("edit-image-modal"),editImageForm:document.getElementById("edit-image-form")};let t=!1,n=[],o="all",a;const i=async(e,t={})=>{const n=await fetch(e,t);if(401===n.status)return c("登录状态已过期","error"),setTimeout(()=>window.location.href="/login.html",2e3),Promise.reject(new Error("Unauthorized"));return n},l=(e,t=2)=>{if(!+e)return"0 Bytes";const n=t<0?0:t,o=["Bytes","KB","MB","GB","TB"];return`${parseFloat((e/Math.pow(1024,Math.floor(Math.log(e)/Math.log(1024)))).toFixed(n))} ${o[Math.floor(Math.log(e)/Math.log(1024))]}`},c=(e,t="success")=>{const n=document.getElementById("toast");n.className=`toast max-w-xs text-white text-sm rounded-lg shadow-lg p-3 ${"success"===t?"bg-green-600":"bg-red-600"}`,n.querySelector("#toast-message").textContent=e,n.style.display="block",setTimeout(()=>n.classList.add("show"),10),setTimeout(()=>{n.classList.remove("show"),setTimeout(()=>n.style.display="none",300)},3e3)};function s(t){t==="stats"?(e.contentView.classList.add("hidden"),e.statsView.classList.remove("hidden"),e.navContent.classList.remove("active"),e.navStats.classList.add("active"),d()):(e.statsView.classList.add("hidden"),e.contentView.classList.remove("hidden"),e.navStats.classList.remove("active"),e.navContent.classList.add("active"))}e.navContent.addEventListener("click",()=>s("content")),e.navStats.addEventListener("click",()=>s("stats"));async function d(){try{const t=await i("/api/admin/stats"),n=await t.json();document.getElementById("stat-uptime").textContent=`${n.uptime.days}天 ${n.uptime.hours}小时`,document.getElementById("stat-views").textContent=n.total_views.toLocaleString(),document.getElementById("stat-ips").textContent=n.unique_ips_today.toLocaleString(),document.getElementById("stat-downloads").textContent=n.total_downloads.toLocaleString(),document.getElementById("stat-traffic").textContent=l(n.traffic_sent_bytes);const o=document.getElementById("stat-popular-downloads");if(o.innerHTML="",n.popular_downloads.length>0)n.popular_downloads.forEach(e=>{const t=document.createElement("li");t.className="flex items-center gap-4 py-2 border-b border-slate-100 last:border-b-0",t.innerHTML=`<img src="${e.thumbnail||"https://via.placeholder.com/40"}" class="w-10 h-10 rounded object-cover bg-slate-200"><p class="flex-grow text-sm text-slate-700 truncate" title="${e.originalFilename}">${e.originalFilename}</p><p class="text-sm font-semibold text-slate-900">${e.count.toLocaleString()} 次</p>`,o.appendChild(t)});else o.innerHTML='<li class="text-slate-500">暂无下载记录。</li>'}catch(t){e.statsView.innerHTML='<p class="text-center text-red-500">加载统计数据失败。</p>'}}function u(n){t=n==="recycle",e.tabGallery.classList.toggle("active",!t),e.tabRecycleBin.classList.toggle("active",t),e.categoryMgmtSection.style.display=t?"none":"block",e.searchContainer.style.display=t?"none":"flex",t?e.searchInput.value="":e.categoryManagementList.querySelector(".active")||e.categoryManagementList.firstElementChild.classList.add("active"),m()}e.tabGallery.addEventListener("click",()=>u("gallery")),e.tabRecycleBin.addEventListener("click",()=>u("recycle"));async function m(){e.imageList.innerHTML="",e.imageLoader.classList.remove("hidden");const a=t?"/api/admin/recyclebin":`/api/images?category=${o}&search=${encodeURIComponent(e.searchInput.value)}&limit=1e3`;try{const o=await i(a),s=await o.json();n=s.images,e.imageLoader.classList.add("hidden");const d=t?"回收站":document.querySelector(".category-item.active .category-name").textContent;e.imageListHeader.innerHTML=`${d} <span class="text-base text-gray-500 font-normal">(${n.length} 张)</span>`,n.length>0?n.forEach(e=>g(e,t)):e.imageList.innerHTML='<p class="text-slate-500 col-span-full text-center">此视图中没有图片。</p>'}catch(t){e.imageLoader.textContent="加载图片失败。"}}function g(n,o){const a=document.createElement("div");a.className=`border rounded-lg shadow-sm bg-white overflow-hidden flex flex-col ${o?"opacity-70":""}`;let i="";i=o?`\n            <button title="恢复" data-id="${n.id}" class="restore-btn p-2 rounded-full text-green-600 hover:bg-green-100 transition-colors"><svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor" class="w-5 h-5"><path stroke-linecap="round" stroke-linejoin="round" d="M16.023 9.348h4.992v-.001M2.985 19.644v-4.992m0 0h4.992m-4.993 0l3.181 3.183a8.25 8.25 0 0011.664 0l3.18-3.185m-4.992-2.686v4.992" /></svg></button>\n            <button title="永久删除" data-id="${n.id}" class="perm-delete-btn p-2 rounded-full text-red-500 hover:bg-red-100 transition-colors"><svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor" class="w-5 h-5"><path stroke-linecap="round" stroke-linejoin="round" d="M14.74 9l-.346 9m-4.788 0L9.26 9m9.968-3.21c.342.052.682.107 1.022.166m-1.022-.165L18.16 19.673a2.25 2.25 0 01-2.244 2.077H8.084a2.25 2.25 0 01-2.244-2.077L4.772 5.79m14.456 0a48.108 48.108 0 00-3.478-.397m-12 .562c.34-.059.68-.114 1.022-.165m0 0a48.11 48.11 0 013.478-.397m7.5 0v-.916c0-1.18-.91-2.134-2.036-2.134H8.718c-1.126 0-2.037.955-2.037 2.134v.916m7.5 0a48.667 48.667 0 00-7.5 0" /></svg></button>\n        `:`\n            <a href="/download/${n.id}" download="${n.originalFilename}" title="下载" class="p-2 rounded-full text-slate-600 hover:bg-slate-200"><svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor" class="w-5 h-5"><path stroke-linecap="round" stroke-linejoin="round" d="M3 16.5v2.25A2.25 2.25 0 005.25 21h13.5A2.25 2.25 0 0021 18.75V16.5M16.5 12L12 16.5m0 0L7.5 12m4.5 4.5V3" /></svg></a>\n            <button title="编辑" data-id="${n.id}" class="edit-btn p-2 rounded-full text-slate-600 hover:bg-slate-200"><svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor" class="w-5 h-5"><path stroke-linecap="round" stroke-linejoin="round" d="M16.862 4.487l1.687-1.688a1.875 1.875 0 112.652 2.652L6.832 19.82a4.5 4.5 0 01-1.897 1.13l-2.685.8.8-2.685a4.5 4.5 0 011.13-1.897L16.863 4.487zm0 0L19.5 7.125" /></svg></button>\n            <button title="删除" data-id="${n.id}" class="delete-btn p-2 rounded-full text-red-500 hover:bg-red-100"><svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor" class="w-5 h-5"><path stroke-linecap="round" stroke-linejoin="round" d="M14.74 9l-.346 9m-4.788 0L9.26 9m9.968-3.21c.342.052.682.107 1.022.166m-1.022-.165L18.16 19.673a2.25 2.25 0 01-2.244 2.077H8.084a2.25 2.25 0 01-2.244-2.077L4.772 5.79m14.456 0a48.108 48.108 0 00-3.478-.397m-12 .562c.34-.059.68-.114 1.022-.165m0 0a48.11 48.11 0 013.478-.397m7.5 0v-.916c0-1.18-.91-2.134-2.036-2.134H8.718c-1.126 0-2.037.955-2.037 2.134v.916m7.5 0a48.667 48.667 0 00-7.5 0" /></svg></button>\n        `,a.innerHTML=`<div class="h-40 bg-slate-100 flex items-center justify-center group"><img src="/image-proxy/${n.filename}?w=400" alt="${n.description}" class="max-h-full max-w-full object-contain group-hover:scale-105 transition-transform"></div><div class="p-3 flex-grow flex flex-col"><p class="font-bold text-sm truncate" title="${n.originalFilename}">${n.originalFilename}</p><p class="text-xs text-slate-500">${l(n.size)}</p><p class="text-xs text-slate-500 mb-2">${o?"已删除":n.category}</p><p class="text-xs text-slate-600 flex-grow mb-3 break-words">${o?"删除于: "+new Date(n.deletedAt).toLocaleString():n.description||"无描述"}</p></div><div class="bg-slate-50 p-2 flex justify-end items-center gap-1">${i}</div>`,e.imageList.appendChild(a)}e.imageList.addEventListener("click",async t=>{const n=t.target.closest("button");if(!n)return;const o=n.dataset.id;if(n.matches(".delete-btn")){if(!await h("确认删除","<p>确定要将这张图片移至回收站吗？</p>","移至回收站"))return;try{const e=await i(`/api/admin/images/${o}`,{method:"DELETE"});if(!e.ok)throw new Error("删除失败");c("图片已移至回收站"),m()}catch(e){c(e.message,"error")}}else if(n.matches(".restore-btn")){try{const e=await i(`/api/admin/recyclebin/restore/${o}`,{method:"POST"});if(!e.ok)throw new Error("恢复失败");c("图片已恢复"),m()}catch(e){c(e.message,"error")}}else if(n.matches(".perm-delete-btn")){if(!await h("永久删除","<p>确定要永久删除这张图片吗？<br><strong>此操作无法撤销！</strong></p>","永久删除"))return;try{const e=await i(`/api/admin/recyclebin/permanent/${o}`,{method:"DELETE"});if(!e.ok)throw new Error("永久删除失败");c("图片已永久删除"),m()}catch(e){c(e.message,"error")}}else if(n.matches(".edit-btn")){const t=currentLoadedImages.find(e=>e.id===o);if(t){await p(),document.getElementById("edit-id").value=t.id,document.getElementById("edit-originalFilename").value=t.originalFilename,document.getElementById("edit-category-select").value=t.category,document.getElementById("edit-description").value=t.description,e.editImageModal.classList.add("active")}}});let h=(t,n,o="确认",a="取消")=>new Promise(i=>{const l=`<button type="button" class="modal-cancel-btn bg-gray-300 hover:bg-gray-400 text-black py-2 px-4 rounded">${a}</button><button type="button" id="modal-confirm-btn" class="bg-red-600 hover:bg-red-700 text-white py-2 px-4 rounded">${o}</button>`;r(t,n,l),e.genericModal.querySelector("#modal-confirm-btn").onclick=()=>{f(e.genericModal),i(!0)},e.genericModal.querySelector(".modal-cancel-btn").onclick=()=>{f(e.genericModal),i(!1)}}),r=(t,n,o)=>{e.genericModal.querySelector("#modal-title").textContent=t,e.genericModal.querySelector("#modal-body").innerHTML=n,e.genericModal.querySelector("#modal-footer").innerHTML=o,e.genericModal.classList.add("active")},f=e=>{e.classList.remove("active")};e.editImageForm.addEventListener("submit",async t=>{t.preventDefault();const n=document.getElementById("edit-id").value,o={originalFilename:document.getElementById("edit-originalFilename").value,category:document.getElementById("edit-category-select").value,description:document.getElementById("edit-description").value};try{const t=await i(`/api/admin/images/${n}`,{method:"PUT",headers:{"Content-Type":"application/json"},body:JSON.stringify(o)});if(!t.ok)throw new Error((await t.json()).message);f(e.editImageModal),c("更新成功"),m()}catch(e){c(`更新失败: ${e.message}`,"error")}}),[e.genericModal,e.editImageModal].forEach(t=>{const n=t.querySelector(".modal-cancel-btn");n&&n.addEventListener("click",()=>f(t)),t.addEventListener("click",e=>{e.target===t&&f(t)})});async function p(){try{const t=await i("/api/categories"),n=await t.json();e.editCategorySelect.innerHTML="",n.forEach(t=>e.editCategorySelect.add(new Option(t,t)))}catch(e){console.error("加载分类失败:",e)}}e.searchInput.addEventListener("input",()=>{clearTimeout(a),a=setTimeout(()=>{m()},300)}),s("content"),u("gallery")});
</script>
</body>
</html>
EOF

    echo -e "${GREEN}--- 所有项目文件已成功生成在 ${INSTALL_DIR} ---${NC}"
    return 0
}

# --- 辅助检查功能 ---
check_port() {
    local port=$1
    echo "--> 正在检查端口 ${port} 是否被占用..."
    if command -v ss &>/dev/null; then
        if ss -Hltn | awk '{print $4}' | grep -q ":${port}$"; then return 1; fi
    elif command -v netstat &>/dev/null; then
        if netstat -lnt | awk '{print $4}' | grep -q ":${port}$"; then return 1; fi
    else
        echo -e "${YELLOW}警告: 无法找到 ss 或 netstat 命令，跳过端口检查。${NC}"
    fi
    return 0
}

# --- 管理菜单功能 ---
check_and_install_deps() {
    local dep_to_check=$1; local package_name=$2; local command_to_check=$3; local sudo_cmd=$4
    command -v "$command_to_check" &> /dev/null && return 0
    echo -e "${YELLOW}--> 检测到核心依赖 '${dep_to_check}' 未安装，正在尝试自动安装...${NC}"
    local pm_cmd=""
    if command -v apt-get &> /dev/null; then
        pm_cmd="apt-get install -y"; echo "--> 检测到 APT 包管理器，正在更新..."
        ${sudo_cmd} apt-get update -y
    elif command -v dnf &> /dev/null; then
        pm_cmd="dnf install -y"; echo "--> 检测到 DNF 包管理器..."
    elif command -v yum &> /dev/null; then
        pm_cmd="yum install -y"; echo "--> 检测到 YUM 包管理器..."
    else
        echo -e "${RED}错误: 未找到 apt, dnf 或 yum 包管理器。请手动安装 '${dep_to_check}' (${package_name})。${NC}"; return 1
    fi
    echo "--> 准备执行: ${sudo_cmd} ${pm_cmd} ${package_name}"
    if eval "${sudo_cmd} ${pm_cmd} ${package_name}"; then
        echo -e "${GREEN}--> '${dep_to_check}' 安装成功！${NC}"; return 0
    else
        echo -e "${RED}--> 自动安装 '${dep_to_check}' 失败。请检查错误并手动安装。${NC}"; return 1
    fi
}

display_status() {
    echo -e "${YELLOW}========================= 应用状态速览 ==========================${NC}"
    printf "  %-15s %b%s%b\n" "管理脚本版本:" "${BLUE}" "v${SCRIPT_VERSION}" "${NC}"
    printf "  %-15s %b%s%b\n" "应用名称:" "${BLUE}" "${APP_NAME}" "${NC}"
    printf "  %-15s %b%s%b\n" "安装路径:" "${BLUE}" "${INSTALL_DIR}" "${NC}"
    printf "  %-15s %b%s%b\n" "备份路径:" "${BLUE}" "${BACKUP_DIR}" "${NC}"

    if [ -d "${INSTALL_DIR}" ] && [ -f "${INSTALL_DIR}/.env" ]; then
        printf "  %-15s %b%s%b\n" "安装状态:" "${GREEN}" "已安装" "${NC}"
        
        cd "${INSTALL_DIR}" >/dev/null 2>&1
        local SERVER_IP; SERVER_IP=$(hostname -I | awk '{print $1}')
        [ -z "${SERVER_IP}" ] && SERVER_IP="127.0.0.1"
        
        local PORT; PORT=$(grep 'PORT=' .env | cut -d '=' -f2)
        local ADMIN_USER; ADMIN_USER=$(grep 'ADMIN_USERNAME=' .env | cut -d '=' -f2)
        local TWO_FA_STATUS; TWO_FA_STATUS=$(grep 'TWO_FACTOR_ENABLED=' .env | cut -d '=' -f2)
        
        if command -v pm2 &> /dev/null && pm2 id "$APP_NAME" &> /dev/null; then
            local pm2_status; pm2_status=$(pm2 show "$APP_NAME" | grep 'status' | awk '{print $4}')
            [ "$pm2_status" == "online" ] && printf "  %-15s %b%s%b\n" "运行状态:" "${GREEN}" "在线 (Online)" "${NC}" || printf "  %-15s %b%s%b\n" "运行状态:" "${RED}" "离线 (Offline)" "${NC}"
        else
            printf "  %-15s %b%s%b\n" "运行状态:" "${YELLOW}" "未知 (PM2未运行)" "${NC}"
        fi
        
        printf "  %-15s %bhttp://%s:%s%b\n" "前台画廊:" "${GREEN}" "${SERVER_IP}" "${PORT}" "${NC}"
        printf "  %-15s %bhttp://%s:%s/admin%b\n" "后台管理:" "${GREEN}" "${SERVER_IP}" "${PORT}" "${NC}"
        printf "  %-15s %b%s%b\n" "后台用户:" "${BLUE}" "${ADMIN_USER}" "${NC}"
        [ "$TWO_FA_STATUS" == "true" ] && printf "  %-15s %b%s%b\n" "2FA状态:" "${GREEN}" "已启用" "${NC}" || printf "  %-15s %b%s%b\n" "2FA状态:" "${RED}" "已关闭" "${NC}"
        cd - >/dev/null 2>&1
    else
        printf "  %-15s %b%s%b\n" "安装状态:" "${RED}" "未安装" "${NC}"
    fi
    echo -e "${YELLOW}==============================================================${NC}"
}

install_app() {
    echo -e "${GREEN}--- 1. 开始安装或修复应用 ---${NC}"
    echo "--> 正在检查系统环境和权限..."
    
    local sudo_cmd=""; [ "$EUID" -ne 0 ] && command -v sudo &> /dev/null && sudo_cmd="sudo"
    
    check_and_install_deps "Node.js & npm" "nodejs npm" "node" "${sudo_cmd}" || return 1
    check_and_install_deps "编译工具(for sharp)" "build-essential" "make" "${sudo_cmd}" || return 1
    check_and_install_deps "qrencode (用于显示2FA二维码)" "qrencode" "qrencode" "${sudo_cmd}"

    echo -e "${YELLOW}--> 正在检查 PM2...${NC}"
    if ! command -v pm2 &> /dev/null; then
        echo -e "${YELLOW}--> 检测到 PM2 未安装，将通过 npm 全局安装...${NC}"
        if ${sudo_cmd} npm install -g pm2; then echo -e "${GREEN}--> PM2 安装成功！${NC}";
        else echo -e "${RED}--> PM2 安装失败。${NC}"; return 1; fi
    else echo -e "${GREEN}--> PM2 已安装。${NC}"; fi

    generate_files || return 1
    cd "${INSTALL_DIR}" || return 1

    echo -e "${YELLOW}--- 安全设置向导 ---${NC}"
    read -p "请输入新的后台管理员用户名 [默认为 admin]: " new_username; new_username=${new_username:-admin}
    
    local new_password
    while true; do
        read -s -p "请输入新的后台管理员密码 (必须填写): " new_password; echo
        read -s -p "请再次输入密码以确认: " new_password_confirm; echo
        if [ "$new_password" == "$new_password_confirm" ] && [ -n "$new_password" ]; then break
        else echo -e "${RED}密码不匹配或为空，请重试。${NC}"; fi
    done
    
    local jwt_secret; jwt_secret=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 64 | head -n 1)
    
    echo "--> 正在创建 .env 配置文件..."
    ( echo "PORT=3000"; echo "ADMIN_USERNAME=${new_username}"; echo "ADMIN_PASSWORD=${new_password}"; echo "JWT_SECRET=${jwt_secret}" ) > .env

    local enable_2fa_choice
    read -p "您是否要为后台启用2FA双因素认证 (推荐)? ${PROMPT_Y}: " enable_2fa_choice
    if [[ "$enable_2fa_choice" == "y" || "$enable_2fa_choice" == "Y" ]]; then
        echo "TWO_FACTOR_ENABLED=true" >> .env
        local two_factor_secret; two_factor_secret=$(head -c 20 /dev/urandom | base32 | tr -d '=' | head -c 32)
        echo "TWO_FACTOR_SECRET=${two_factor_secret}" >> .env
        echo -e "${GREEN}--> 2FA 已启用！${NC}"
        echo -e "${RED}!! 重要 !! 请立即使用您的 Authenticator 应用扫描二维码或手动输入密钥：${NC}"
        
        local otp_url="otpauth://totp/${APP_NAME}:${new_username}?secret=${two_factor_secret}&issuer=${APP_NAME}"
        if command -v qrencode &>/dev/null; then
            echo "二维码:"
            qrencode -t ANSIUTF8 "$otp_url"
        else
            echo "请将此URL复制到浏览器或2FA工具中: ${otp_url}"
        fi
        echo -e "${YELLOW}密钥 (备用): ${two_factor_secret}${NC}"
        echo -e "${RED}请务必在继续前完成此步骤！这是唯一一次显示此密钥的机会。${NC}"
        read -n 1 -s -r -p "完成扫描后，按任意键继续..."
    else
        echo "TWO_FACTOR_ENABLED=false" >> .env; echo "TWO_FACTOR_SECRET=" >> .env
        echo -e "${YELLOW}--> 2FA 未启用。${NC}"
    fi
    
    echo -e "${YELLOW}--> 正在安装项目依赖 (npm install)，这可能需要几分钟...${NC}"
    if npm install; then echo -e "${GREEN}--> 项目依赖安装成功！${NC}";
    else echo -e "${RED}--> npm install 失败，请检查错误日志。${NC}"; return 1; fi

    echo -e "${GREEN}--- 安装完成！正在自动启动应用... ---${NC}"; start_app
}

start_app() {
    echo -e "${GREEN}--- 正在启动应用... ---${NC}"
    [ ! -f "${INSTALL_DIR}/.env" ] && { echo -e "${RED}错误: 应用未安装。请先运行安装程序。${NC}"; return 1; }
    cd "${INSTALL_DIR}" || return 1
    
    local PORT; PORT=$(grep 'PORT=' .env | cut -d '=' -f2)
    if ! check_port "$PORT"; then
        echo -e "${RED}错误: 端口 ${PORT} 已被占用！${NC}"; return 1
    fi
    echo -e "${GREEN}--> 端口 ${PORT} 可用。${NC}"
    
    local sudo_cmd=""; [ "$EUID" -ne 0 ] && command -v sudo &>/dev/null && sudo_cmd="sudo"
    ${sudo_cmd} pm2 start server.js --name "$APP_NAME"; ${sudo_cmd} pm2 startup; ${sudo_cmd} pm2 save --force
    echo -e "${GREEN}--- 应用已启动！---${NC}"
}

stop_app() {
    echo -e "${YELLOW}--- 正在停止应用... ---${NC}"
    [ ! -d "${INSTALL_DIR}" ] && { echo -e "${RED}错误: 应用未安装。${NC}"; return 1; }
    local sudo_cmd=""; [ "$EUID" -ne 0 ] && command -v sudo &>/dev/null && sudo_cmd="sudo"
    ${sudo_cmd} pm2 stop "$APP_NAME"; echo -e "${GREEN}--- 应用已停止！---${NC}"
}

restart_app() {
    echo -e "${GREEN}--- 正在重启应用... ---${NC}"
    [ ! -f "${INSTALL_DIR}/.env" ] && { echo -e "${RED}错误: 应用未安装。${NC}"; return 1; }
    cd "${INSTALL_DIR}" || return 1
    local PORT; PORT=$(grep 'PORT=' .env | cut -d '=' -f2)
    if ! check_port "$PORT"; then
        echo -e "${RED}错误: 端口 ${PORT} 已被占用！无法重启。${NC}"; return 1
    fi
    local sudo_cmd=""; [ "$EUID" -ne 0 ] && command -v sudo &>/dev/null && sudo_cmd="sudo"
    ${sudo_cmd} pm2 restart "$APP_NAME"; echo -e "${GREEN}--- 应用已重启！---${NC}"
}

view_logs() {
    echo -e "${YELLOW}--- 显示应用日志 (按 Ctrl+C 退出)... ---${NC}"
    [ ! -d "${INSTALL_DIR}" ] && { echo -e "${RED}错误: 应用未安装。${NC}"; return 1; }
    local sudo_cmd=""; [ "$EUID" -ne 0 ] && command -v sudo &>/dev/null && sudo_cmd="sudo"
    ${sudo_cmd} pm2 logs "$APP_NAME"
}

manage_credentials() {
    echo -e "${YELLOW}--- 修改后台用户名/密码 ---${NC}"
    [ ! -f "${INSTALL_DIR}/.env" ] && { echo -e "${RED}错误: 应用未安装。${NC}"; return 1; }
    cd "${INSTALL_DIR}" || return 1

    local CURRENT_USER; CURRENT_USER=$(grep 'ADMIN_USERNAME=' .env | cut -d '=' -f2)
    echo "当前用户名: ${CURRENT_USER}"
    read -p "请输入新的用户名 (留空则不修改): " new_username
    read -s -p "请输入新的密码 (留空则不修改): " new_password; echo
    
    if [ -z "$new_username" ] && [ -z "$new_password" ]; then echo -e "${YELLOW}未做任何修改。${NC}"; return; fi
    [ -n "$new_username" ] && { sed -i "/^ADMIN_USERNAME=/c\\ADMIN_USERNAME=${new_username}" .env; echo -e "${GREEN}用户名已更新为: ${new_username}${NC}"; }
    [ -n "$new_password" ] && { sed -i "/^ADMIN_PASSWORD=/c\\ADMIN_PASSWORD=${new_password}" .env; echo -e "${GREEN}密码已更新。${NC}"; }
    
    echo -e "${YELLOW}正在重启应用以使新凭据生效...${NC}"; restart_app
}

manage_port() {
    echo -e "${YELLOW}--- 修改应用端口号 ---${NC}"
    [ ! -f "${INSTALL_DIR}/.env" ] && { echo -e "${RED}错误: 应用未安装。${NC}"; return 1; }
    cd "${INSTALL_DIR}" || return 1

    local CURRENT_PORT; CURRENT_PORT=$(grep 'PORT=' .env | cut -d '=' -f2)
    echo "当前端口号: ${CURRENT_PORT}"
    read -p "请输入新的端口号 (1024-65535, 留空则不修改): " new_port
    
    if [ -z "$new_port" ]; then echo -e "${YELLOW}未做任何修改。${NC}"; return; fi
    
    if ! [[ "$new_port" =~ ^[0-9]+$ ]] || [ "$new_port" -lt 1024 ] || [ "$new_port" -gt 65535 ]; then
        echo -e "${RED}错误: 无效的端口号。请输入 1024 到 65535 之间的数字。${NC}"; return 1
    fi
    
    sed -i "/^PORT=/c\\PORT=${new_port}" .env
    echo -e "${GREEN}端口号已更新为: ${new_port}${NC}"
    echo -e "${YELLOW}正在重启应用以使新端口生效...${NC}"; restart_app
}

manage_2fa() {
    echo -e "${YELLOW}--- 管理2FA (双因素认证) ---${NC}"
    [ ! -f "${INSTALL_DIR}/.env" ] && { echo -e "${RED}错误: 应用未安装。${NC}"; return 1; }
    cd "${INSTALL_DIR}" || return 1

    local current_status; current_status=$(grep 'TWO_FACTOR_ENABLED=' .env | cut -d '=' -f2)

    if [ "$current_status" == "true" ]; then
        echo -e "当前2FA状态: ${GREEN}已启用${NC}"
        echo "您可以选择:"
        echo "  1. 关闭 2FA"
        echo "  2. 重置 2FA 密钥"
        echo "  0. 返回主菜单"
        read -p "请输入您的选择 [0-2]: " choice

        case $choice in
            1)
                echo "--> 正在关闭 2FA..."
                sed -i "/^TWO_FACTOR_ENABLED=/c\\TWO_FACTOR_ENABLED=false" .env
                sed -i "/^TWO_FACTOR_SECRET=/c\\TWO_FACTOR_SECRET=" .env
                echo -e "${GREEN}2FA 已成功关闭。${NC}"
                echo -e "${YELLOW}正在重启应用...${NC}"; restart_app
                ;;
            2)
                echo "--> 正在重置 2FA 密钥..."
                local new_secret; new_secret=$(head -c 20 /dev/urandom | base32 | tr -d '=' | head -c 32)
                sed -i "/^TWO_FACTOR_SECRET=/c\\TWO_FACTOR_SECRET=${new_secret}" .env
                local username; username=$(grep 'ADMIN_USERNAME=' .env | cut -d '=' -f2)
                echo -e "${GREEN}--> 新的2FA密钥已生成！${NC}"
                echo -e "${RED}!! 重要 !! 请立即使用新的密钥或二维码重新设置您的 Authenticator 应用：${NC}"
                local otp_url="otpauth://totp/${APP_NAME}:${username}?secret=${new_secret}&issuer=${APP_NAME}"
                if command -v qrencode &>/dev/null; then
                    echo "新二维码:"; qrencode -t ANSIUTF8 "$otp_url"
                else
                    echo "请将此URL复制到浏览器或2FA工具中: ${otp_url}"
                fi
                echo -e "${YELLOW}新密钥 (备用): ${new_secret}${NC}"
                read -n 1 -s -r -p "完成扫描后，按任意键继续..."
                echo -e "${YELLOW}正在重启应用...${NC}"; restart_app
                ;;
            *) echo -e "${YELLOW}操作已取消。${NC}";;
        esac
    else
        echo -e "当前2FA状态: ${RED}已关闭${NC}"
        read -p "您想现在启用2FA吗? ${PROMPT_Y}: " choice
        if [[ "$choice" == "y" || "$choice" == "Y" ]]; then
            echo "--> 正在启用 2FA..."
            sed -i "/^TWO_FACTOR_ENABLED=/c\\TWO_FACTOR_ENABLED=true" .env
            local new_secret; new_secret=$(head -c 20 /dev/urandom | base32 | tr -d '=' | head -c 32)
            if grep -q "^TWO_FACTOR_SECRET=" .env; then
                sed -i "/^TWO_FACTOR_SECRET=/c\\TWO_FACTOR_SECRET=${new_secret}" .env
            else
                echo "TWO_FACTOR_SECRET=${new_secret}" >> .env
            fi
            local username; username=$(grep 'ADMIN_USERNAME=' .env | cut -d '=' -f2)
            echo -e "${GREEN}--> 2FA 已成功启用！${NC}"
            echo -e "${RED}!! 重要 !! 请立即使用您的 Authenticator 应用扫描二维码或手动输入密钥：${NC}"
            local otp_url="otpauth://totp/${APP_NAME}:${username}?secret=${new_secret}&issuer=${APP_NAME}"
            if command -v qrencode &>/dev/null; then
                echo "二维码:"; qrencode -t ANSIUTF8 "$otp_url"
            else
                echo "请将此URL复制到浏览器或2FA工具中: ${otp_url}"
            fi
            echo -e "${YELLOW}密钥 (备用): ${new_secret}${NC}"
            read -n 1 -s -r -p "完成扫描后，按任意键继续..."
            echo -e "${YELLOW}正在重启应用...${NC}"; restart_app
        else
            echo -e "${YELLOW}操作已取消。${NC}"
        fi
    fi
}

backup_app() {
    echo -e "${YELLOW}--- 正在备份应用数据... ---${NC}"
    [ ! -d "${INSTALL_DIR}" ] && { echo -e "${RED}错误: 应用未安装。${NC}"; return 1; }
    
    mkdir -p "${BACKUP_DIR}"
    local backup_filename="backup-$(date +%Y%m%d-%H%M%S).tar.gz"
    local backup_filepath="${BACKUP_DIR}/${backup_filename}"
    
    echo "--> 目标文件: ${backup_filepath}"
    if tar -czf "${backup_filepath}" -C "${INSTALL_DIR}" public/uploads data; then
        echo -e "${GREEN}--- 备份成功！文件已保存至: ${backup_filepath} ---${NC}"
    else
        echo -e "${RED}--- 备份失败！ ---${NC}"
    fi
}

restore_app() {
    echo -e "${YELLOW}--- 从备份恢复应用数据 ---${NC}"
    [ ! -d "${INSTALL_DIR}" ] && { echo -e "${RED}错误: 应用未安装。${NC}"; return 1; }
    [ ! -d "${BACKUP_DIR}" ] || [ -z "$(ls -A ${BACKUP_DIR}/*.tar.gz 2>/dev/null)" ] && { echo -e "${RED}错误: 未找到任何备份文件。${NC}"; return 1; }

    echo "可用备份文件列表:"
    select backup_file in "${BACKUP_DIR}"/*.tar.gz; do
        [ -n "$backup_file" ] && break || { echo -e "${RED}无效选择。${NC}"; continue; }
    done
    
    echo -e "${RED}警告：此操作将覆盖当前所有图片和数据，且【无法撤销】！${NC}"
    read -p "您确定要从 '$(basename "$backup_file")' 文件恢复吗? ${PROMPT_Y}: " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then echo -e "${YELLOW}操作已取消。${NC}"; return; fi
    
    echo "--> 正在停止应用以安全恢复..."
    stop_app
    
    echo "--> 正在清理旧数据..."
    rm -rf "${INSTALL_DIR}/public/uploads" "${INSTALL_DIR}/data"
    mkdir -p "${INSTALL_DIR}/public/uploads" "${INSTALL_DIR}/data"
    
    echo "--> 正在从备份文件恢复..."
    if tar -xzf "$backup_file" -C "${INSTALL_DIR}"; then
        echo -e "${GREEN}--- 恢复成功！---${NC}"
        echo -e "${YELLOW}建议您立即启动应用来验证恢复的数据。${NC}"
    else
        echo -e "${RED}--- 恢复失败！ ---${NC}"
    fi
}

uninstall_app() {
    echo -e "${RED}========================= 彻底卸载警告 =========================${NC}"
    echo "此操作将【永久删除】应用、所有上传的图片、所有数据和配置。"
    echo -e "目标删除路径: ${YELLOW}${INSTALL_DIR}${NC}"
    echo -e "${RED}==============================================================${NC}"
    
    read -p "您是否要在卸载前创建一个最终备份? ${PROMPT_Y}: " backup_confirm
    if [[ "$backup_confirm" == "y" || "$backup_confirm" == "Y" ]]; then backup_app; fi
    
    read -p "$(echo -e "${YELLOW}您是否仍要继续彻底卸载? ${PROMPT_Y}: ")" confirm
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        echo "--> 正在从 PM2 中删除应用..."
        local sudo_cmd=""; [ "$EUID" -ne 0 ] && command -v sudo &>/dev/null && sudo_cmd="sudo"
        command -v pm2 &> /dev/null && { ${sudo_cmd} pm2 delete "$APP_NAME" &> /dev/null; ${sudo_cmd} pm2 save --force &> /dev/null; }
        echo "--> 正在永久删除项目文件夹: ${INSTALL_DIR}..."
        rm -rf "${INSTALL_DIR}"
        echo -e "${GREEN}应用已彻底卸载。${NC}"
    else
        echo -e "${YELLOW}操作已取消。${NC}"
    fi
}

show_menu() {
    clear
    display_status
    echo ""
    echo -e "${YELLOW}-------------------------- 可用操作 --------------------------${NC}"
    echo -e " ${YELLOW}【基础操作】${NC}"
    printf "   %-3s %s\n" "1." "安装或修复应用"
    printf "   %-3s %s\n" "2." "启动应用"
    printf "   %-3s %s\n" "3." "停止应用"
    printf "   %-3s %s\n" "4." "重启应用"
    echo ""
    echo -e " ${YELLOW}【维护与管理】${NC}"
    printf "   %-3s %s\n" "5." "查看应用状态 (刷新)"
    printf "   %-3s %s\n" "6." "查看实时日志"
    printf "   %-3s %s\n" "7." "修改后台配置 (用户名/密码)"
    printf "   %-3s %s\n" "8." "修改端口号"
    printf "   %-3s %b\n" "9." "${YELLOW}管理2FA (开启/关闭/重置)${NC}"
    printf "   %-3s %b\n" "10." "${GREEN}备份应用数据${NC}"
    printf "   %-3s %b\n" "11." "${YELLOW}从备份恢复数据${NC}"
    echo ""
    echo -e " ${YELLOW}【危险操作】${NC}"
    printf "   %-3s %b\n" "12." "${RED}彻底卸载应用${NC}"
    echo ""
    printf "   %-3s %s\n" "0." "退出脚本"
    echo -e "${YELLOW}--------------------------------------------------------------${NC}"
}

main_loop() {
    local choice
    read -p "请输入你的选择 [0-12]: " choice
    
    case $choice in
        1) install_app ;; 2) start_app ;; 3) stop_app ;; 4) restart_app ;;
        5) ;; 6) view_logs ;; 7) manage_credentials ;; 8) manage_port ;;
        9) manage_2fa ;; 10) backup_app ;; 11) restore_app ;; 12) uninstall_app ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效输入...${NC}" ;;
    esac

    if [[ "$choice" != "0" ]]; then read -n 1 -s -r -p "按任意键返回主菜单..."; fi
}

# --- 脚本主入口 ---
while true; do
    show_menu
    main_loop
done
