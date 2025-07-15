#!/bin/bash

# =================================================================
#   图片画廊 专业版 - 一体化部署与管理脚本 (v0.0.1 全功能增强版)
#
#   作者: 编码助手 (经 Gemini Pro 优化)
#   v0.0.1 更新:
#   - 新增: 核心的数据备份与恢复功能，保障用户数据安全。
#   - 新增: 灵活的端口修改功能，并自动重启应用。
#   - 增强: 启动应用前进行端口占用检查，提升启动成功率。
#   - 增强: 卸载前提供最终备份选项，让危险操作更安全。
#   - 优化: 移除冗余的 body-parser 依赖，项目结构更清晰。
#   - 调整: 全新的菜单布局和版本号。
# =================================================================

# --- 配置 ---
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color
PROMPT_Y="(${GREEN}y${NC}/${RED}n${NC})"

SCRIPT_VERSION="0.0.1"
APP_NAME="image-gallery"

# --- 路径设置 (核心改进：路径将基于脚本自身位置，确保唯一性) ---
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

    echo "--> 正在生成 package.json (已移除body-parser)..."
cat << 'EOF' > package.json
{
  "name": "image-gallery-pro",
  "version": "10.0.0",
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
    "sharp": "^0.33.3",
    "uuid": "^9.0.1"
  }
}
EOF

    echo "--> 正在生成后端服务器 server.js (已使用express内置body-parser)..."
cat << 'EOF' > server.js
const express = require('express');
const multer = require('multer');
const path = require('path');
const fs = require('fs').promises;
const { v4: uuidv4 } = require('uuid');
const cookieParser = require('cookie-parser');
const jwt = require('jsonwebtoken');
const sharp = require('sharp');
require('dotenv').config();

const app = express();
const PORT = process.env.PORT || 3000;
const ADMIN_USERNAME = process.env.ADMIN_USERNAME || 'admin';
const ADMIN_PASSWORD = process.env.ADMIN_PASSWORD || 'password';
const JWT_SECRET = process.env.JWT_SECRET;
const AUTH_TOKEN_NAME = 'auth_token';
const UNCATEGORIZED = '未分类';

const dbPath = path.join(__dirname, 'data', 'images.json');
const categoriesPath = path.join(__dirname, 'data', 'categories.json');
const uploadsDir = path.join(__dirname, 'public', 'uploads');
const cacheDir = path.join(__dirname, 'public', 'cache');

const initializeDirectories = async () => {
    try {
        await fs.mkdir(path.join(__dirname, 'data'), { recursive: true });
        await fs.mkdir(uploadsDir, { recursive: true });
        await fs.mkdir(cacheDir, { recursive: true });
    } catch (error) { console.error('初始化目录失败:', error); process.exit(1); }
};

// 使用 Express 内置的中间件替代 body-parser
app.use(express.json());
app.use(express.urlencoded({ extended: true }));
app.use(cookieParser());

const readDB = async (filePath) => {
    try { await fs.access(filePath); const data = await fs.readFile(filePath, 'utf-8'); return data.trim() === '' ? [] : JSON.parse(data); } 
    catch (error) { if (error.code === 'ENOENT') return []; console.error(`读取DB时出错: ${filePath}`, error); return []; }
};
const writeDB = async (filePath, data) => {
    try { await fs.writeFile(filePath, JSON.stringify(data, null, 2)); } 
    catch (error) { console.error(`写入DB时出错: ${filePath}`, error); }
};

const authMiddleware = (isApi) => (req, res, next) => {
    const token = req.cookies[AUTH_TOKEN_NAME];
    if (!token) { return isApi ? res.status(401).json({ message: '认证失败' }) : res.redirect('/login.html'); }
    try { jwt.verify(token, JWT_SECRET); next(); } 
    catch (err) { return isApi ? res.status(401).json({ message: '认证令牌无效或已过期' }) : res.redirect('/login.html'); }
};
const requirePageAuth = authMiddleware(false);
const requireApiAuth = authMiddleware(true);

app.post('/api/login', (req, res) => {
    const { username, password } = req.body;
    if (username === ADMIN_USERNAME && password === ADMIN_PASSWORD) {
        const token = jwt.sign({ username }, JWT_SECRET, { expiresIn: '1d' });
        res.cookie(AUTH_TOKEN_NAME, token, { httpOnly: true, secure: process.env.NODE_ENV === 'production', maxAge: 86400000 });
        res.redirect('/admin.html');
    } else { res.redirect('/login.html?error=1'); }
});
app.get('/api/logout', (req, res) => { res.clearCookie(AUTH_TOKEN_NAME); res.redirect('/login.html'); });
app.get('/admin.html', requirePageAuth, (req, res) => res.sendFile(path.join(__dirname, 'public', 'admin.html')));
app.get('/admin', requirePageAuth, (req, res) => res.redirect('/admin.html'));

app.get('/api/images', async (req, res) => {
    let images = await readDB(dbPath);
    const { category, search, page = 1, limit = 12 } = req.query;

    if (search) {
        const searchTerm = search.toLowerCase();
        images = images.filter(img => (img.originalFilename && img.originalFilename.toLowerCase().includes(searchTerm)) || (img.description && img.description.toLowerCase().includes(searchTerm)));
    }
    
    if (category && category !== 'all' && category !== 'random') {
        images = images.filter(img => img.category === category);
    } else if (category === 'random') {
        images.sort(() => 0.5 - Math.random());
    } else {
        images.sort((a, b) => new Date(b.uploadedAt) - new Date(a.uploadedAt));
    }
    
    const pageNum = parseInt(page);
    const limitNum = parseInt(limit);
    const startIndex = (pageNum - 1) * limitNum;
    const endIndex = pageNum * limitNum;
    
    const paginatedImages = images.slice(startIndex, endIndex);
    const totalImages = images.length;

    res.json({
        images: paginatedImages,
        page: pageNum,
        limit: limitNum,
        totalPages: Math.ceil(totalImages / limitNum),
        totalImages: totalImages,
        hasMore: endIndex < totalImages
    });
});

app.get('/api/categories', async (req, res) => {
    const categories = await readDB(categoriesPath);
    res.json(categories.sort((a,b) => a === UNCATEGORIZED ? -1 : b === UNCATEGORIZED ? 1 : a.localeCompare(b, 'zh-CN')));
});

app.get('/api/public/categories', async (req, res) => {
    const allDefinedCategories = await readDB(categoriesPath);
    const images = await readDB(dbPath);
    const categoriesInUse = new Set(images.map(img => img.category));
    let categoriesToShow = allDefinedCategories.filter(cat => categoriesInUse.has(cat));
    res.json(categoriesToShow.sort((a,b) => a === UNCATEGORIZED ? -1 : b === UNCATEGORIZED ? 1 : a.localeCompare(b, 'zh-CN')));
});

app.get('/image-proxy/:filename', async (req, res) => {
    const { filename } = req.params;
    const { w, h, format } = req.query;
    const width = w ? parseInt(w) : null;
    const height = h ? parseInt(h) : null;
    const originalPath = path.join(uploadsDir, filename);
    const ext = path.extname(filename);
    const name = path.basename(filename, ext);
    const browserAcceptsWebP = req.headers.accept && req.headers.accept.includes('image/webp');
    const targetFormat = (format === 'webp' || (browserAcceptsWebP && format !== 'jpeg')) ? 'webp' : 'jpeg';
    const mimeType = `image/${targetFormat}`;
    const cacheFilename = `${name}_w${width || 'auto'}_h${height || 'auto'}.${targetFormat}`;
    const cachePath = path.join(cacheDir, cacheFilename);

    try {
        await fs.access(cachePath);
        res.sendFile(cachePath);
    } catch (error) {
        try {
            await fs.access(originalPath);
            const transformer = sharp(originalPath).resize(width, height, { fit: 'inside', withoutEnlargement: true });
            const processedImageBuffer = await (targetFormat === 'webp' ? transformer.webp({ quality: 80 }) : transformer.jpeg({ quality: 85 })).toBuffer();
            await fs.writeFile(cachePath, processedImageBuffer);
            res.setHeader('Content-Type', mimeType);
            res.send(processedImageBuffer);
        } catch (procError) { res.status(404).send('Image not found or processing failed.'); }
    }
});

const apiAdminRouter = express.Router();
apiAdminRouter.use(requireApiAuth);
const storage = multer.diskStorage({ destination: (req, file, cb) => cb(null, uploadsDir), filename: (req, file, cb) => { const uniqueSuffix = uuidv4(); const extension = path.extname(file.originalname); cb(null, `${uniqueSuffix}${extension}`); } });
const upload = multer({ storage: storage });

apiAdminRouter.post('/check-filenames', async(req, res) => {
    const { filenames } = req.body;
    if (!Array.isArray(filenames)) { return res.status(400).json({message: 'Invalid input'}); }
    try {
        const images = await readDB(dbPath);
        const existingFilenames = new Set(images.map(img => img.originalFilename));
        const duplicates = filenames.filter(name => existingFilenames.has(name));
        res.json({ duplicates });
    } catch (error) {
        res.status(500).json({message: "Error reading database"});
    }
});

apiAdminRouter.post('/upload', upload.single('image'), async (req, res) => {
    if (!req.file) return res.status(400).json({ message: '没有选择文件。' });
    try {
        const metadata = await sharp(req.file.path).metadata();
        const images = await readDB(dbPath);
        
        let originalFilename = req.file.originalname;
        const existingFilenames = new Set(images.map(img => img.originalFilename));
        if (req.body.rename === 'true' && existingFilenames.has(originalFilename)) {
            const ext = path.extname(originalFilename);
            const baseName = path.basename(originalFilename, ext);
            let counter = 1;
            do {
                originalFilename = `${baseName} (${counter})${ext}`;
                counter++;
            } while (existingFilenames.has(originalFilename));
        }

        const newImage = { 
            id: uuidv4(), src: `/uploads/${req.file.filename}`, 
            category: req.body.category || UNCATEGORIZED, 
            description: req.body.description || '', 
            originalFilename: originalFilename,
            filename: req.file.filename, 
            size: req.file.size, uploadedAt: new Date().toISOString(),
            width: metadata.width, height: metadata.height
        };
        images.unshift(newImage);
        await writeDB(dbPath, images);
        res.status(200).json({ message: '上传成功', image: newImage });
    } catch (error) { console.error('Upload processing error:', error); res.status(500).json({message: '上传失败，处理图片信息时出错。'}) }
});
apiAdminRouter.delete('/images/:id', async (req, res) => {
    let images = await readDB(dbPath);
    const imageToDelete = images.find(img => img.id === req.params.id);
    if (!imageToDelete) return res.status(404).json({ message: '图片未找到' });
    const filePath = path.join(uploadsDir, imageToDelete.filename);
    try { await fs.unlink(filePath); } catch (error) { console.error(`删除文件失败: ${filePath}`, error); }
    const updatedImages = images.filter(img => img.id !== req.params.id);
    await writeDB(dbPath, updatedImages);
    res.json({ message: '删除成功' });
});
apiAdminRouter.put('/images/:id', async (req, res) => {
    let images = await readDB(dbPath);
    const { category, description, originalFilename } = req.body;
    const imageIndex = images.findIndex(img => img.id === req.params.id);
    if (imageIndex === -1) return res.status(404).json({ message: '图片未找到' });
    const imageToUpdate = { ...images[imageIndex] };
    imageToUpdate.category = category || imageToUpdate.category;
    imageToUpdate.description = description === undefined ? imageToUpdate.description : description;
    if (originalFilename && originalFilename !== imageToUpdate.originalFilename) {
        const existingFilenames = new Set(images.map(img => img.originalFilename).filter(name => name !== images[imageIndex].originalFilename));
        if (existingFilenames.has(originalFilename)) { return res.status(409).json({ message: '该文件名已存在。'}); }
        imageToUpdate.originalFilename = originalFilename;
    }
    images[imageIndex] = imageToUpdate;
    await writeDB(dbPath, images);
    res.json({ message: '更新成功', image: imageToUpdate });
});
apiAdminRouter.post('/categories', async (req, res) => {
    const { name } = req.body;
    if (!name || name.trim() === '') return res.status(400).json({ message: '分类名称不能为空。' });
    let categories = await readDB(categoriesPath);
    if (categories.includes(name)) return res.status(409).json({ message: '该分类已存在。' });
    categories.push(name);
    await writeDB(categoriesPath, categories);
    res.status(201).json({ message: '分类创建成功', category: name });
});
apiAdminRouter.delete('/categories', async (req, res) => {
    const { name } = req.body;
    if (!name || name === UNCATEGORIZED) return res.status(400).json({ message: '无效的分类或“未分类”无法删除。' });
    let categories = await readDB(categoriesPath);
    if (!categories.includes(name)) return res.status(404).json({ message: '该分类不存在。' });
    const updatedCategories = categories.filter(cat => cat !== name);
    await writeDB(categoriesPath, updatedCategories);
    let images = await readDB(dbPath);
    images.forEach(img => { if (img.category === name) { img.category = UNCATEGORIZED; } });
    await writeDB(dbPath, images);
    res.status(200).json({ message: `分类 '${name}' 已删除，相关图片已归入 '${UNCATEGORIZED}'。` });
});
apiAdminRouter.put('/categories', async (req, res) => {
    const { oldName, newName } = req.body;
    if (!oldName || !newName || oldName === newName || oldName === UNCATEGORIZED) return res.status(400).json({ message: '无效的分类名称。' });
    let categories = await readDB(categoriesPath);
    if (!categories.includes(oldName)) return res.status(404).json({ message: '旧分类不存在。' });
    if (categories.includes(newName)) return res.status(409).json({ message: '新的分类名称已存在。' });
    const updatedCategories = categories.map(cat => (cat === oldName ? newName : cat));
    await writeDB(categoriesPath, updatedCategories);
    let images = await readDB(dbPath);
    images.forEach(img => { if (img.category === oldName) { img.category = newName; } });
    await writeDB(dbPath, images);
    res.status(200).json({ message: `分类 '${oldName}' 已重命名为 '${newName}'。` });
});
app.use('/api/admin', apiAdminRouter);
app.use(express.static(path.join(__dirname, 'public')));
(async () => {
    if (!JWT_SECRET) { console.error(`错误: JWT_SECRET 未在 .env 文件中设置。`); process.exit(1); }
    await initializeDirectories();
    app.listen(PORT, () => console.log(`服务器正在 http://localhost:${PORT} 运行`));
})();
EOF

    echo "--> 正在生成主画廊 public/index.html (v19.0.0 体验优化版)..."
cat << 'EOF' > public/index.html
<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>图片画廊</title>
    <meta name="description" content="一个展示精彩瞬间的瀑布流图片画廊。">

    <link rel="preconnect" href="https://fonts.googleapis.com">
    <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
    <link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;700&family=Noto+Sans+SC:wght@400;500;700&display=swap" rel="stylesheet">
    <script src="https://cdn.tailwindcss.com"></script>

    <style>
        :root {
            --bg-color: #f0fdf4;
            --text-color: #14532d;
            --header-bg-scrolled: rgba(240, 253, 244, 0.85);
            --filter-btn-color: #166534;
            --filter-btn-hover-bg: #dcfce7;
            --filter-btn-active-bg: #22c55e;
            --filter-btn-active-border: #16a34a;
            --grid-item-bg: #e4e4e7;
            --search-bg: #ffffff;
            --search-placeholder-color: #9ca3af;
            --divider-color: #dcfce7; /* 页脚边框颜色 */
        }

        body.dark {
            --bg-color: #111827;
            --text-color: #a7f3d0;
            --header-bg-scrolled: rgba(17, 24, 39, 0.85);
            --filter-btn-color: #a7f3d0;
            --filter-btn-hover-bg: #1f2937;
            --filter-btn-active-bg: #16a34a;
            --filter-btn-active-border: #15803d;
            --grid-item-bg: #374151;
            --search-bg: #1f2937;
            --search-placeholder-color: #6b7280;
            --divider-color: #166534;
        }
        
        body { font-family: 'Inter', 'Noto Sans SC', sans-serif; background-color: var(--bg-color); color: var(--text-color); }
        body.overflow-hidden { overflow: hidden; }

        .header-sticky { padding-top: 1rem; padding-bottom: 1rem; background-color: rgba(240, 253, 244, 0); position: sticky; top: 0; z-index: 40; box-shadow: 0 1px 2px 0 rgba(0, 0, 0, 0.05); transition: padding 0.3s ease-in-out, background-color 0.3s ease-in-out; }
        .header-sticky #header-top { transition: opacity 0.3s ease-in-out, height 0.3s ease-in-out, margin-bottom 0.3s ease-in-out; }
        .header-sticky.is-scrolled { padding-top: 0.5rem; padding-bottom: 0.5rem; background-color: var(--header-bg-scrolled); backdrop-filter: blur(8px); }
        .header-sticky.is-scrolled #header-top { opacity: 0; height: 0; margin-bottom: 0; pointer-events: none; overflow: hidden; }
        
        #search-overlay { opacity: 0; visibility: hidden; transition: opacity 0.3s ease, visibility 0s 0.3s; }
        #search-overlay.active { opacity: 1; visibility: visible; transition: opacity 0.3s ease, visibility 0s 0s; }
        #search-box { transform: scale(0.95); opacity: 0; transition: transform 0.3s ease, opacity 0.3s ease; }
        #search-overlay.active #search-box { transform: scale(1); opacity: 1; }
        
        .grid-gallery { display: grid; grid-template-columns: repeat(auto-fill, minmax(180px, 1fr)); grid-auto-rows: 10px; gap: 1rem; }
        .grid-item { position: relative; border-radius: 0.5rem; overflow: hidden; background-color: var(--grid-item-bg); box-shadow: 0 4px 6px -1px rgb(0 0 0 / 0.1), 0 2px 4px -2px rgb(0 0 0 / 0.1); opacity: 0; transform: translateY(20px); transition: opacity 0.5s ease-out, transform 0.5s ease-out, box-shadow 0.3s ease; }
        .grid-item-wide { grid-column: span 2; }
        @media (max-width: 400px) { .grid-item-wide { grid-column: span 1; } }
        .grid-item.is-visible { opacity: 1; transform: translateY(0); }
        .grid-item img { cursor: pointer; width: 100%; height: 100%; object-fit: cover; display: block; transition: transform 0.4s ease; }
        .grid-item:hover img { transform: scale(1.05); }

        .filter-btn { padding: 0.5rem 1rem; border-radius: 9999px; font-weight: 500; transition: all 0.2s ease; border: 1px solid transparent; cursor: pointer; background-color: transparent; color: var(--filter-btn-color); }
        .filter-btn:hover { background-color: var(--filter-btn-hover-bg); }
        .filter-btn.active { background-color: var(--filter-btn-active-bg); color: white; border-color: var(--filter-btn-active-border); }
        
        .lightbox { position: fixed; top: 0; left: 0; width: 100%; height: 100%; background-color: rgba(0, 0, 0, 0.9); display: flex; justify-content: center; align-items: center; z-index: 1000; opacity: 0; visibility: hidden; transition: opacity 0.3s ease; }
        .lightbox.active { opacity: 1; visibility: visible; }
        .lightbox-image { max-width: 85%; max-height: 85%; display: block; object-fit: contain; }
        .lightbox-btn { position: absolute; top: 50%; transform: translateY(-50%); background-color: rgba(255,255,255,0.1); color: white; border: none; font-size: 2.5rem; cursor: pointer; padding: 0.5rem 1rem; border-radius: 0.5rem; transition: background-color 0.2s; }
        .lightbox-btn:hover { background-color: rgba(255,255,255,0.2); }
        .lb-prev { left: 1rem; } .lb-next { right: 1rem; } .lb-close { top: 1rem; right: 1rem; font-size: 2rem; }
        .lb-counter { position: absolute; top: 1.5rem; left: 50%; transform: translateX(-50%); color: white; font-size: 1rem; background-color: rgba(0,0,0,0.3); padding: 0.25rem 0.75rem; border-radius: 9999px; }
        .lb-download { position: absolute; bottom: 1rem; right: 1rem; background-color: #22c55e; color: white; border: none; padding: 0.5rem 1rem; border-radius: 0.5rem; cursor: pointer; transition: background-color 0.2s; font-size: 1rem; text-decoration: none; }
        .lb-download:hover { background-color: #16a34a; }
        .back-to-top { position: fixed; bottom: 2rem; right: 2rem; background-color: #22c55e; color: white; width: 3rem; height: 3rem; border-radius: 9999px; display: flex; align-items: center; justify-content: center; box-shadow: 0 4px 8px rgba(0,0,0,0.2); cursor: pointer; opacity: 0; visibility: hidden; transform: translateY(20px); transition: all 0.3s ease; }
        .back-to-top.visible { opacity: 1; visibility: visible; transform: translateY(0); }
    </style>
</head>
<body class="antialiased">

    <header class="text-center header-sticky">
        <div id="header-top" class="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 flex items-center justify-between h-auto md:h-14 mb-4">
            <div class="w-1/3"></div>
            <h1 class="text-4xl md:text-5xl font-bold w-1/3 whitespace-nowrap">图片画廊</h1>
            <div class="w-1/3 flex items-center justify-end gap-1">
                <button id="search-toggle-btn" title="搜索" class="p-2 rounded-full text-[var(--text-color)] hover:bg-gray-500/10">
                    <svg class="w-6 h-6" xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor"><path stroke-linecap="round" stroke-linejoin="round" d="m21 21-5.197-5.197m0 0A7.5 7.5 0 1 0 5.196 5.196a7.5 7.5 0 0 0 10.607 10.607Z" /></svg>
                </button>
                <button id="theme-toggle" title="切换主题" class="p-2 rounded-full text-[var(--text-color)] hover:bg-gray-500/10">
                    <svg id="theme-icon-sun" class="w-6 h-6" fill="none" viewBox="0 0 24 24" stroke="currentColor"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 3v1m0 16v1m9-9h-1M4 12H3m15.364 6.364l-.707-.707M6.343 6.343l-.707-.707m12.728 0l-.707.707M6.343 17.657l-.707.707M16 12a4 4 0 11-8 0 4 4 0 018 0z" /></svg>
                    <svg id="theme-icon-moon" class="w-6 h-6 hidden" fill="none" viewBox="0 0 24 24" stroke="currentColor"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M20.354 15.354A9 9 0 018.646 3.646 9.003 9.003 0 0012 21a9.003 9.003 0 008.354-5.646z" /></svg>
                </button>
            </div>
        </div>
        <div id="filter-buttons" class="flex justify-center flex-wrap gap-2 px-4">
            <button class="filter-btn active" data-filter="all">全部</button>
            <button class="filter-btn" data-filter="random">随机</button>
        </div>
    </header>
    
    <div class="border-b-2" style="border-color: var(--divider-color);"></div>

    <main class="container mx-auto px-6 py-8 md:py-10">
        <div id="gallery-container" class="max-w-7xl mx-auto grid-gallery"></div>
        <div id="loader" class="text-center py-8 hidden">正在加载更多...</div>
    </main>
    
    <footer class="text-center py-8 mt-auto border-t" style="border-color: var(--divider-color);">
        <p>© 2025 图片画廊</p>
    </footer>

    <div id="search-overlay" class="fixed inset-0 z-50 flex items-start justify-center pt-24 md:pt-32 p-4 bg-black/30">
        <div id="search-box" class="w-full max-w-lg relative flex items-center gap-2">
            <div class="absolute top-1/2 left-5 -translate-y-1/2 text-gray-400">
                <svg class="w-6 h-6" xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="2" stroke="currentColor"><path stroke-linecap="round" stroke-linejoin="round" d="m21 21-5.197-5.197m0 0A7.5 7.5 0 1 0 5.196 5.196a7.5 7.5 0 0 0 10.607 10.607Z" /></svg>
            </div>
            <input type="search" id="search-input" placeholder="输入关键词，按 Enter 或点击按钮..." class="w-full py-4 pl-14 pr-5 text-lg rounded-lg border-0 shadow-2xl focus:ring-2 focus:ring-green-500" style="background-color: var(--search-bg); color: var(--text-color);">
            <button id="search-exec-btn" class="bg-green-600 hover:bg-green-700 text-white font-bold py-4 px-5 rounded-lg transition-colors absolute right-0 top-0 h-full">
                <svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="2" stroke="currentColor" class="w-6 h-6"><path stroke-linecap="round" stroke-linejoin="round" d="m21 21-5.197-5.197m0 0A7.5 7.5 0 1 0 5.196 5.196a7.5 7.5 0 0 0 10.607 10.607Z" /></svg>
            </button>
        </div>
    </div>
    
    <div class="lightbox"><span class="lb-counter"></span><button class="lightbox-btn lb-close">&times;</button><button class="lightbox-btn lb-prev">&lsaquo;</button><img class="lightbox-image" alt=""><button class="lightbox-btn lb-next">&rsaquo;</button><a href="#" id="lightbox-download-link" download class="lb-download">下载</a></div>
    <a class="back-to-top" title="返回顶部"><svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 19V5M5 12l7-7 7 7"/></svg></a>

    <script>
    document.addEventListener('DOMContentLoaded', function () {
        const body = document.body;
        const galleryContainer = document.getElementById('gallery-container');
        const loader = document.getElementById('loader');
        const filterButtonsContainer = document.getElementById('filter-buttons');
        const header = document.querySelector('.header-sticky');
        let allLoadedImages = []; let currentFilter = 'all'; let currentSearch = ''; let currentPage = 1; let isLoading = false; let hasMoreImages = true; let debounceTimer; let lastFocusedElement;
        
        const searchToggleBtn = document.getElementById('search-toggle-btn');
        const themeToggleBtn = document.getElementById('theme-toggle');
        const themeIconSun = document.getElementById('theme-icon-sun');
        const themeIconMoon = document.getElementById('theme-icon-moon');
        const searchOverlay = document.getElementById('search-overlay');
        const searchInput = document.getElementById('search-input');
        const searchExecBtn = document.getElementById('search-exec-btn');
        
        const openSearch = () => { searchOverlay.classList.add('active'); body.classList.add('overflow-hidden'); setTimeout(() => searchInput.focus(), 50); };
        const closeSearch = () => { searchOverlay.classList.remove('active'); body.classList.remove('overflow-hidden'); };
        searchToggleBtn.addEventListener('click', openSearch);
        searchOverlay.addEventListener('click', (e) => { if (e.target === searchOverlay) closeSearch(); });
        document.addEventListener('keydown', (e) => { if (e.key === 'Escape' && searchOverlay.classList.contains('active')) closeSearch(); });
        
        const performSearch = () => {
            const newSearchTerm = searchInput.value.trim();
            currentSearch = newSearchTerm;
            document.querySelectorAll('.filter-btn').forEach(btn => btn.classList.remove('active'));
            filterButtonsContainer.querySelector('[data-filter="all"]').classList.add('active');
            currentFilter = 'all';
            closeSearch(); resetGallery(); fetchAndRenderImages();
        };
        searchInput.addEventListener('keydown', (e) => { if (e.key === 'Enter') performSearch(); });
        searchExecBtn.addEventListener('click', performSearch);
        
        const applyTheme = (theme) => { if (theme === 'dark') { body.classList.add('dark'); themeIconSun.classList.add('hidden'); themeIconMoon.classList.remove('hidden'); } else { body.classList.remove('dark'); themeIconSun.classList.remove('hidden'); themeIconMoon.classList.add('hidden'); } };
        themeToggleBtn.addEventListener('click', () => { const newTheme = body.classList.contains('dark') ? 'light' : 'dark'; localStorage.setItem('theme', newTheme); applyTheme(newTheme); });
        applyTheme(localStorage.getItem('theme') || (window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light'));

        const fetchJSON = async (url) => { const response = await fetch(url); if (!response.ok) throw new Error(`HTTP error! status: ${response.status}`); return response.json(); };
        const resetGallery = () => { galleryContainer.innerHTML = ''; allLoadedImages = []; currentPage = 1; hasMoreImages = true; window.scrollTo(0, 0); };
        const fetchAndRenderImages = async () => {
            if (isLoading || !hasMoreImages) return;
            isLoading = true;
            loader.classList.remove('hidden');
            try {
                const url = `/api/images?page=${currentPage}&limit=12&category=${currentFilter}&search=${encodeURIComponent(currentSearch)}`;
                const data = await fetchJSON(url);
                loader.classList.add('hidden');
                if (data.images && data.images.length > 0) { renderItems(data.images); allLoadedImages.push(...data.images); currentPage++; hasMoreImages = data.hasMore; } 
                else { hasMoreImages = false; if (allLoadedImages.length === 0) loader.textContent = '没有找到符合条件的图片。'; }
            } catch (error) { console.error('获取图片数据失败:', error); loader.textContent = '加载失败，请刷新页面。'; } 
            finally { isLoading = false; if (!hasMoreImages && allLoadedImages.length > 0) loader.classList.add('hidden'); }
        };

        const renderItems = (images) => {
            images.forEach(image => {
                const item = document.createElement('div');
                item.className = 'grid-item'; item.dataset.id = image.id;
                const img = document.createElement('img');
                img.src = "data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7";
                img.dataset.src = `/image-proxy/${image.filename}?w=400`; img.alt = image.description || image.originalFilename;
                img.onerror = () => { item.remove(); };
                item.appendChild(img); galleryContainer.appendChild(item); imageObserver.observe(item);
            });
        };
        const imageObserver = new IntersectionObserver((entries, observer) => {
            entries.forEach(entry => {
                if (entry.isIntersecting) {
                    const item = entry.target; const img = item.querySelector('img'); img.src = img.dataset.src;
                    img.onload = () => { item.style.backgroundColor = 'transparent'; item.classList.add('is-visible'); resizeSingleGridItem(item); };
                    observer.unobserve(item);
                }
            });
        }, { rootMargin: '0px 0px 200px 0px' });
        
        const resizeSingleGridItem = (item) => {
            const img = item.querySelector('img');
            if (!img || !img.complete || img.naturalHeight === 0) return;
            const imageInData = allLoadedImages.find(i => i.id === item.dataset.id); if (!imageInData) return;
            const rowHeight = 10; const rowGap = 16;
            const ratio = imageInData.width / imageInData.height;
            if (ratio > 1.2) item.classList.add('grid-item-wide'); else item.classList.remove('grid-item-wide');
            const clientWidth = item.clientWidth;
            if (clientWidth > 0) { const scaledHeight = clientWidth / ratio; const rowSpan = Math.ceil((scaledHeight + rowGap) / (rowHeight + rowGap)); item.style.gridRowEnd = `span ${rowSpan}`; }
        };
        const resizeAllGridItems = () => { const items = galleryContainer.querySelectorAll('.grid-item.is-visible'); items.forEach(resizeSingleGridItem); };
        window.addEventListener('resize', () => { clearTimeout(debounceTimer); debounceTimer = setTimeout(resizeAllGridItems, 200); });
        
        const createFilterButtons = async () => {
            try {
                const categories = await fetchJSON('/api/public/categories');
                filterButtonsContainer.querySelectorAll('.dynamic-filter').forEach(btn => btn.remove());
                categories.forEach(category => {
                    const button = document.createElement('button'); button.className = 'filter-btn dynamic-filter'; button.dataset.filter = category; button.textContent = category;
                    filterButtonsContainer.appendChild(button);
                });
            } catch (error) { console.error('无法加载分类按钮:', error); }
        };
        filterButtonsContainer.addEventListener('click', (e) => {
            const target = e.target.closest('.filter-btn');
            if (!target) return;
            currentFilter = target.dataset.filter; currentSearch = ''; searchInput.value = '';
            document.querySelectorAll('.filter-btn').forEach(btn => btn.classList.remove('active'));
            target.classList.add('active');
            resetGallery(); fetchAndRenderImages();
        });

        const lightbox = document.querySelector('.lightbox'); const lightboxImage = lightbox.querySelector('.lightbox-image'); const lbCounter = lightbox.querySelector('.lb-counter'); const lbDownloadLink = document.getElementById('lightbox-download-link'); let currentImageIndexInFiltered = 0;
        galleryContainer.addEventListener('click', (e) => { const item = e.target.closest('.grid-item'); if (item) { lastFocusedElement = document.activeElement; currentImageIndexInFiltered = allLoadedImages.findIndex(img => img.id === item.dataset.id); if (currentImageIndexInFiltered === -1) return; updateLightbox(); lightbox.classList.add('active'); document.body.classList.add('overflow-hidden'); } });
        const updateLightbox = () => { const currentItem = allLoadedImages[currentImageIndexInFiltered]; if (!currentItem) return; lightboxImage.src = currentItem.src; lightboxImage.alt = currentItem.description; lbCounter.textContent = `${currentImageIndexInFiltered + 1} / ${allLoadedImages.length}`; lbDownloadLink.href = currentItem.src; lbDownloadLink.download = currentItem.originalFilename; };
        const showPrevImage = () => { currentImageIndexInFiltered = (currentImageIndexInFiltered - 1 + allLoadedImages.length) % allLoadedImages.length; updateLightbox(); };
        const showNextImage = () => { currentImageIndexInFiltered = (currentImageIndexInFiltered + 1) % allLoadedImages.length; updateLightbox(); };
        const closeLightbox = () => { lightbox.classList.remove('active'); document.body.classList.remove('overflow-hidden'); if(lastFocusedElement) lastFocusedElement.focus(); };
        lightbox.addEventListener('click', (e) => { const target = e.target; if (target.matches('.lb-next')) showNextImage(); else if (target.matches('.lb-prev')) showPrevImage(); else if (target.matches('.lb-close') || target === lightbox) closeLightbox(); });
        document.addEventListener('keydown', (e) => { if (lightbox.classList.contains('active')) { if (e.key === 'ArrowLeft') showPrevImage(); else if (e.key === 'ArrowRight') showNextImage(); else if (e.key === 'Escape') closeLightbox(); } });
        
        const backToTopBtn = document.querySelector('.back-to-top'); let ticking = false;
        backToTopBtn.addEventListener('click', () => window.scrollTo({ top: 0, behavior: 'smooth' })); 
        
        function handleScroll() {
            const currentScrollY = window.scrollY;
            if (currentScrollY > 300) { backToTopBtn.classList.add('visible'); } 
            else { backToTopBtn.classList.remove('visible'); } 
            if (currentScrollY > 10) { header.classList.add('is-scrolled'); } 
            else { header.classList.remove('is-scrolled'); }
            if (window.innerHeight + window.scrollY >= document.body.offsetHeight - 500) { fetchAndRenderImages(); } 
        }

        window.addEventListener('scroll', () => { 
            if (!ticking) { window.requestAnimationFrame(() => { handleScroll(); ticking = false; }); ticking = true; }
        }); 

        (async function init() { await createFilterButtons(); await fetchAndRenderImages(); })();
    });
    </script>
</body>
</html>
EOF

    echo "--> 正在生成后台登录页 public/login.html..."
cat << 'EOF' > public/login.html
<!DOCTYPE html><html lang="zh-CN"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0"><title>后台登录 - 图片画廊</title><script src="https://cdn.tailwindcss.com"></script><style> body { background-color: #f0fdf4; } </style></head><body class="antialiased text-green-900"><div class="min-h-screen flex items-center justify-center"><div class="max-w-md w-full bg-white p-8 rounded-lg shadow-lg"><h1 class="text-3xl font-bold text-center text-green-900 mb-6">后台管理登录</h1><div id="error-message" class="hidden bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded relative mb-4" role="alert"><strong class="font-bold">登录失败！</strong><span class="block sm:inline">用户名或密码不正确。</span></div><form action="/api/login" method="POST"><div class="mb-4"><label for="username" class="block text-green-800 text-sm font-bold mb-2">用户名</label><input type="text" id="username" name="username" required class="shadow appearance-none border rounded w-full py-2 px-3 text-gray-700 leading-tight focus:outline-none focus:ring-2 focus:ring-green-500"></div><div class="mb-6"><label for="password" class="block text-green-800 text-sm font-bold mb-2">密码</label><input type="password" id="password" name="password" required class="shadow appearance-none border rounded w-full py-2 px-3 text-gray-700 mb-3 leading-tight focus:outline-none focus:ring-2 focus:ring-green-500"></div><div class="flex items-center justify-between"><button type="submit" class="w-full bg-green-600 hover:bg-green-700 text-white font-bold py-2 px-4 rounded-lg focus:outline-none focus:shadow-outline transition-colors"> 登 录 </button></div></form></div></div><script> const urlParams = new URLSearchParams(window.location.search); if (urlParams.has('error')) { document.getElementById('error-message').classList.remove('hidden'); } </script></body></html>
EOF

    echo "--> 正在生成后台管理页 public/admin.html..."
cat << 'EOF' > public/admin.html
<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0"><title>后台管理 - 图片画廊</title>
    <script src="https://cdn.tailwindcss.com"></script>
    <style> body { background-color: #f8fafc; } .modal, .toast, .lightbox { display: none; } .modal.active, .lightbox.active { display: flex; } body.lightbox-open { overflow: hidden; } .category-item.active { background-color: #dcfce7; font-weight: bold; } .toast { position: fixed; top: 1.5rem; right: 1.5rem; z-index: 9999; transform: translateX(120%); transition: transform 0.3s ease-in-out; } .toast.show { transform: translateX(0); } .file-preview-item.upload-success { background-color: #f0fdf4; } .file-preview-item.upload-error { background-color: #fef2f2; } .lightbox { position: fixed; top: 0; left: 0; width: 100%; height: 100%; background-color: rgba(0, 0, 0, 0.9); justify-content: center; align-items: center; z-index: 1000; opacity: 0; visibility: hidden; transition: opacity 0.3s ease; } .lightbox.active { opacity: 1; visibility: visible; } .lightbox-image { max-width: 85%; max-height: 85%; display: block; object-fit: contain; } .lightbox-btn { position: absolute; top: 50%; transform: translateY(-50%); background-color: rgba(255,255,255,0.1); color: white; border: none; font-size: 2.5rem; cursor: pointer; padding: 0.5rem 1rem; border-radius: 0.5rem; transition: background-color 0.2s; } .lb-prev { left: 1rem; } .lb-next { right: 1rem; } .lb-close { top: 1rem; right: 1rem; font-size: 2rem; } .lb-download { position: absolute; bottom: 1rem; right: 1rem; background-color: #22c55e; color: white; border: none; padding: 0.5rem 1rem; border-radius: 0.5rem; cursor: pointer; transition: background-color 0.2s; font-size: 1rem; text-decoration: none; } .lb-download:hover { background-color: #16a34a; } #file-preview-list { resize: vertical; } .category-item { outline: none !important; } .category-item:focus { box-shadow: none !important; ring: 0 !important; } </style>
</head>
<body class="antialiased text-slate-800">
    <header class="bg-white shadow-md p-4 flex justify-between items-center sticky top-0 z-20">
        <h1 class="text-2xl font-bold text-slate-900">内容管理系统</h1>
        <div class="flex items-center gap-2">
            <a href="/" target="_blank" title="查看前台" class="flex items-center gap-2 bg-white border border-gray-300 text-gray-700 font-semibold py-2 px-4 rounded-lg hover:bg-gray-50 transition-colors">
                <svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor" class="w-5 h-5"><path stroke-linecap="round" stroke-linejoin="round" d="M13.5 6H5.25A2.25 2.25 0 003 8.25v10.5A2.25 2.25 0 005.25 21h10.5A2.25 2.25 0 0018 18.75V10.5m-4.5 0V6.375c0-.621.504-1.125 1.125-1.125h1.125c.621 0 1.125.504 1.125 1.125V10.5m-4.5 0h4.5m-4.5 0a2.25 2.25 0 01-2.25-2.25V8.25c0-.621.504-1.125 1.125-1.125h1.125c.621 0 1.125.504 1.125 1.125v3.375M3 11.25h1.5m1.5 0h1.5m-1.5 0l1.5-1.5m-1.5 1.5l-1.5-1.5m9 6.75l1.5-1.5m-1.5 1.5l-1.5-1.5" /></svg>
                <span class="hidden sm:inline">查看前台</span>
            </a>
            <a href="/api/logout" title="退出登录" class="flex items-center gap-2 bg-red-600 hover:bg-red-700 text-white font-bold py-2 px-4 rounded-lg transition-colors">
                <svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor" class="w-5 h-5"><path stroke-linecap="round" stroke-linejoin="round" d="M15.75 9V5.25A2.25 2.25 0 0013.5 3h-6a2.25 2.25 0 00-2.25 2.25v13.5A2.25 2.25 0 007.5 21h6a2.25 2.25 0 002.25-2.25V15M12 9l-3 3m0 0l3 3m-3-3h12.75" /></svg>
                <span class="hidden sm:inline">退出登录</span>
            </a>
        </div>
    </header>
    <main class="container mx-auto p-4 md:p-6 grid grid-cols-1 xl:grid-cols-12 gap-8">
        <div class="xl:col-span-4 space-y-8">
            <section id="upload-section" class="bg-white p-6 rounded-lg shadow-md">
                <h2 class="text-xl font-semibold mb-4">上传新图片</h2>
                <form id="upload-form" class="space-y-4">
                    <div><label for="image-input" id="drop-zone" class="w-full flex flex-col items-center justify-center p-6 border-2 border-dashed border-gray-300 rounded-lg cursor-pointer hover:bg-gray-50 transition-colors"><svg class="w-10 h-10 mb-3 text-gray-400" aria-hidden="true" xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 20 16"><path stroke="currentColor" stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M13 13h3a3 3 0 0 0 0-6h-.025A5.56 5.56 0 0 0 16 6.5 5.5 5.5 0 0 0 5.207 5.021C5.137 5.017 5.071 5 5 5a4 4 0 0 0 0 8h2.167M10 15V6m0 0L8 8m2-2 2 2"/></svg><p class="text-sm text-gray-500"><span class="font-semibold">点击选择</span> 或拖拽多个文件到此处</p><input id="image-input" type="file" class="hidden" multiple accept="image/*"/></label></div>
                    <div class="space-y-2"><label for="unified-description" class="block text-sm font-medium">统一描述 (可选)</label><textarea id="unified-description" rows="2" class="w-full text-sm border rounded px-2 py-1" placeholder="在此处填写可应用到所有未填写描述的图片"></textarea></div>
                    <div id="file-preview-container" class="hidden space-y-2"><div id="upload-summary" class="text-sm font-medium text-slate-600"></div><div id="file-preview-list" class="h-48 border rounded p-2 space-y-3" style="overflow: auto; resize: vertical;"></div></div>
                    <div><label for="category-select" class="block text-sm font-medium mb-1">设置分类</label><div class="flex items-center space-x-2"><select name="category" id="category-select" required class="w-full border rounded px-3 py-2 focus:outline-none focus:ring-2 focus:ring-green-500"></select><button type="button" id="add-category-btn" class="flex-shrink-0 bg-green-500 hover:bg-green-600 text-white font-bold w-9 h-9 rounded-full flex items-center justify-center text-xl" title="添加新分类">+</button></div></div>
                    <button type="submit" id="upload-btn" class="w-full bg-green-600 hover:bg-green-700 text-white font-bold py-2 px-4 rounded-lg transition-colors disabled:bg-gray-400" disabled>上传文件</button>
                </form>
            </section>
            <section class="bg-white p-6 rounded-lg shadow-md"><h2 class="text-xl font-semibold mb-4">分类管理</h2><div id="category-management-list" class="space-y-2"></div></section>
        </div>
        <section class="bg-white p-6 rounded-lg shadow-md xl:col-span-8">
            <div class="flex flex-col md:flex-row justify-between items-center mb-4 gap-4"><h2 id="image-list-header" class="text-xl font-semibold text-slate-900 flex-grow"></h2><div class="w-full md:w-64"><input type="search" id="search-input" placeholder="搜索文件名或描述..." class="w-full border rounded-full px-4 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-green-500"></div></div>
            <div id="image-list" class="grid grid-cols-1 sm:grid-cols-2 md:grid-cols-2 lg:grid-cols-3 2xl:grid-cols-4 gap-4"></div>
            <div id="image-loader" class="text-center py-8 text-slate-500 hidden">正在加载...</div>
        </section>
    </main>
    <div id="generic-modal" class="modal fixed inset-0 bg-black bg-opacity-50 items-center justify-center z-30 p-4"><div class="bg-white rounded-lg shadow-xl p-6 w-full max-w-sm"><h3 id="modal-title" class="text-lg font-bold mb-4"></h3><div id="modal-body" class="mb-4 text-slate-600"></div><div id="modal-footer" class="flex justify-end space-x-2"></div></div></div>
    <div id="edit-image-modal" class="modal fixed inset-0 bg-black bg-opacity-50 items-center justify-center z-30 p-4"><div class="bg-white rounded-lg shadow-xl p-6 w-full max-w-md"><h3 class="text-lg font-bold mb-4">编辑图片信息</h3><form id="edit-image-form"><input type="hidden" id="edit-id"><div class="mb-4"><label for="edit-originalFilename" class="block text-sm font-medium mb-1">原始文件名</label><input type="text" id="edit-originalFilename" class="w-full border rounded px-3 py-2"></div><div class="mb-4"><label for="edit-category-select" class="block text-sm font-medium mb-1">分类</label><select id="edit-category-select" class="w-full border rounded px-3 py-2"></select></div><div class="mb-4"><label for="edit-description" class="block text-sm font-medium mb-1">描述</label><textarea id="edit-description" rows="3" class="w-full border rounded px-3 py-2"></textarea></div><div class="flex justify-end space-x-2 mt-6"><button type="button" class="modal-cancel-btn bg-gray-300 hover:bg-gray-400 text-black py-2 px-4 rounded">取消</button><button type="submit" class="bg-blue-600 hover:bg-blue-700 text-white py-2 px-4 rounded">保存更改</button></div></form></div></div>
    <div id="admin-lightbox" class="lightbox"><button class="lightbox-btn lb-close">&times;</button><button class="lightbox-btn lb-prev">&lsaquo;</button><img class="lightbox-image" alt="Lightbox preview"><button class="lightbox-btn lb-next">&rsaquo;</button><a href="#" id="admin-lightbox-download-link" download class="lb-download">下载</a></div>
    <div id="toast" class="toast max-w-xs bg-gray-800 text-white text-sm rounded-lg shadow-lg p-3" role="alert"><div class="flex items-center"><div id="toast-icon" class="mr-2"></div><span id="toast-message"></span></div></div>
    <script>
    document.addEventListener('DOMContentLoaded', function() {
        const UNCATEGORIZED = '未分类'; const DOMElements = { uploadForm: document.getElementById('upload-form'), uploadBtn: document.getElementById('upload-btn'), imageInput: document.getElementById('image-input'), dropZone: document.getElementById('drop-zone'), unifiedDescription: document.getElementById('unified-description'), filePreviewContainer: document.getElementById('file-preview-container'), filePreviewList: document.getElementById('file-preview-list'), uploadSummary: document.getElementById('upload-summary'), categorySelect: document.getElementById('category-select'), editCategorySelect: document.getElementById('edit-category-select'), addCategoryBtn: document.getElementById('add-category-btn'), categoryManagementList: document.getElementById('category-management-list'), imageList: document.getElementById('image-list'), imageListHeader: document.getElementById('image-list-header'), imageLoader: document.getElementById('image-loader'), searchInput: document.getElementById('search-input'), genericModal: document.getElementById('generic-modal'), editImageModal: document.getElementById('edit-image-modal'), editImageForm: document.getElementById('edit-image-form'), adminLightbox: document.getElementById('admin-lightbox'), };
        let filesToUpload = []; let adminLoadedImages = []; let currentAdminLightboxIndex = 0; let currentSearchTerm = ''; let debounceTimer;
        const apiRequest = async (url, options = {}) => { const response = await fetch(url, options); if (response.status === 401) { showToast('登录状态已过期', 'error'); setTimeout(() => window.location.href = '/login.html', 2000); throw new Error('Unauthorized'); } return response; };
        const formatBytes = (bytes, decimals = 2) => { if (!+bytes) return '0 Bytes'; const k = 1024; const dm = decimals < 0 ? 0 : decimals; const sizes = ["Bytes", "KB", "MB", "GB", "TB"]; const i = Math.floor(Math.log(bytes) / Math.log(k)); return `${parseFloat((bytes / Math.pow(k, i)).toFixed(dm))} ${sizes[i]}`; };
        const showToast = (message, type = 'success') => { const toast = document.getElementById('toast'); toast.className = `toast max-w-xs text-white text-sm rounded-lg shadow-lg p-3 ${type === 'success' ? 'bg-green-600' : 'bg-red-600'}`; toast.querySelector('#toast-message').textContent = message; toast.querySelector('#toast-icon').innerHTML = type === 'success' ? `<svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M5 13l4 4L19 7"></path></svg>` : `<svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 8v4m0 4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z"></path></svg>`; toast.style.display = 'block'; setTimeout(() => toast.classList.add('show'), 10); setTimeout(() => { toast.classList.remove('show'); setTimeout(() => toast.style.display = 'none', 300); }, 3000); };
        const showGenericModal = (title, bodyHtml, footerHtml) => { DOMElements.genericModal.querySelector('#modal-title').textContent = title; DOMElements.genericModal.querySelector('#modal-body').innerHTML = bodyHtml; DOMElements.genericModal.querySelector('#modal-footer').innerHTML = footerHtml; DOMElements.genericModal.classList.add('active'); };
        const showConfirmationModal = (title, bodyHtml, confirmText = '确认', cancelText = '取消') => { return new Promise(resolve => { const footerHtml = `<button type="button" class="modal-cancel-btn bg-gray-300 hover:bg-gray-400 text-black py-2 px-4 rounded">${cancelText}</button><button type="button" id="modal-confirm-btn" class="bg-red-600 hover:bg-red-700 text-white py-2 px-4 rounded">${confirmText}</button>`; showGenericModal(title, bodyHtml, footerHtml); DOMElements.genericModal.querySelector('#modal-confirm-btn').onclick = () => { hideModal(DOMElements.genericModal); resolve(true); }; const cancelBtn = DOMElements.genericModal.querySelector('.modal-cancel-btn'); cancelBtn.onclick = () => { hideModal(DOMElements.genericModal); resolve(false); }; DOMElements.genericModal.onclick = (e) => { if (e.target === DOMElements.genericModal) { cancelBtn.click(); } }; }); };
        const hideModal = (modal) => modal.classList.remove('active');
        const handleFileSelection = (fileList) => { const imageFiles = Array.from(fileList).filter(f => f.type.startsWith('image/')); const currentFilenames = new Set(filesToUpload.map(item => item.file.name)); const newFiles = imageFiles.filter(f => !currentFilenames.has(f.name)).map(file => ({ file, description: DOMElements.unifiedDescription.value, userHasTyped: DOMElements.unifiedDescription.value !== '', shouldRename: false, status: 'pending' })); filesToUpload.push(...newFiles); DOMElements.uploadBtn.disabled = filesToUpload.length === 0; renderFilePreviews(); };
        const renderFilePreviews = () => { if (filesToUpload.length === 0) { DOMElements.filePreviewContainer.classList.add('hidden'); return; } DOMElements.filePreviewList.innerHTML = ''; let totalSize = 0; filesToUpload.forEach((item, index) => { totalSize += item.file.size; const listItem = document.createElement('div'); const tempId = `file-preview-${index}`; listItem.className = 'file-preview-item text-slate-600 border rounded p-2'; listItem.dataset.fileIndex = index; listItem.innerHTML = `<div class="flex items-start"><img class="w-12 h-12 object-cover rounded mr-3 bg-slate-100" id="thumb-${tempId}"><div class="flex-grow"><div class="flex justify-between items-center text-xs mb-1"><p class="truncate pr-2 font-medium">${item.file.name}</p><button type="button" data-index="${index}" class="remove-file-btn text-xl text-red-500 hover:text-red-700 leading-none">&times;</button></div><p class="text-xs text-slate-500">${formatBytes(item.file.size)}</p></div></div><input type="text" data-index="${index}" class="relative w-full text-xs border rounded px-2 py-1 description-input bg-transparent mt-2" placeholder="添加独立描述..." value="${item.description}"><p class="upload-status text-xs mt-1"></p>`; DOMElements.filePreviewList.appendChild(listItem); const reader = new FileReader(); reader.onload = (e) => { document.getElementById(`thumb-${tempId}`).src = e.target.result; }; reader.readAsDataURL(item.file); }); DOMElements.uploadSummary.textContent = `已选择 ${filesToUpload.length} 个文件，总大小: ${formatBytes(totalSize)}`; DOMElements.filePreviewContainer.classList.remove('hidden'); };
        const dz = DOMElements.dropZone; dz.addEventListener('dragover', (e) => { e.preventDefault(); dz.classList.add('bg-green-50', 'border-green-400'); }); dz.addEventListener('dragleave', (e) => dz.classList.remove('bg-green-50', 'border-green-400')); dz.addEventListener('drop', (e) => { e.preventDefault(); dz.classList.remove('bg-green-50', 'border-green-400'); handleFileSelection(e.dataTransfer.files); });
        DOMElements.imageInput.addEventListener('change', (e) => { handleFileSelection(e.target.files); e.target.value = ''; });
        DOMElements.unifiedDescription.addEventListener('input', e => { const unifiedText = e.target.value; document.querySelectorAll('.file-preview-item').forEach(item => { const index = parseInt(item.dataset.fileIndex, 10); if (filesToUpload[index] && !filesToUpload[index].userHasTyped) { item.querySelector('.description-input').value = unifiedText; filesToUpload[index].description = unifiedText; } }); });
        DOMElements.filePreviewList.addEventListener('input', e => { if (e.target.classList.contains('description-input')) { const index = parseInt(e.target.dataset.index, 10); if(filesToUpload[index]) { filesToUpload[index].description = e.target.value; filesToUpload[index].userHasTyped = true; } } });
        DOMElements.filePreviewList.addEventListener('click', e => { if (e.target.classList.contains('remove-file-btn')) { const index = parseInt(e.target.dataset.index, 10); filesToUpload.splice(index, 1); renderFilePreviews(); DOMElements.uploadBtn.disabled = filesToUpload.length === 0; } });
        
        const processUploadQueue = async (e) => {
            e.preventDefault();
            DOMElements.uploadBtn.disabled = true;
            
            const pendingFiles = filesToUpload.filter(f => f.status === 'pending');
            if (pendingFiles.length === 0) { showToast("没有需要上传的新文件。", "error"); DOMElements.uploadBtn.disabled = filesToUpload.length === 0; return; }
            
            const filenamesToCheck = pendingFiles.map(item => item.file.name);
            const checkRes = await apiRequest('/api/admin/check-filenames', { method: 'POST', headers: {'Content-Type': 'application/json'}, body: JSON.stringify({filenames: filenamesToCheck}) });
            const { duplicates } = await checkRes.json();
            
            for (const item of pendingFiles) {
                if (duplicates.includes(item.file.name)) {
                    const userConfirmed = await showConfirmationModal('文件已存在', `文件 "<strong>${item.file.name}</strong>" 已存在。是否仍然继续上传？<br>(新文件将被自动重命名)`, '继续上传', '取消此文件');
                    if (userConfirmed) { item.shouldRename = true; } 
                    else {
                        item.status = 'cancelled';
                        const previewItem = DOMElements.filePreviewList.querySelector(`[data-file-index="${filesToUpload.indexOf(item)}"]`);
                        if(previewItem) previewItem.querySelector('.upload-status').textContent = '已取消';
                    }
                }
            }

            const uploadableFiles = filesToUpload.filter(f => f.status === 'pending');
            let processedCount = 0;
            const updateButtonText = () => { DOMElements.uploadBtn.textContent = `正在上传 (${processedCount}/${uploadableFiles.length})...`; };
            if (uploadableFiles.length > 0) updateButtonText();

            for (const item of uploadableFiles) {
                const originalIndex = filesToUpload.indexOf(item);
                const previewItem = DOMElements.filePreviewList.querySelector(`[data-file-index="${originalIndex}"]`);
                if (!previewItem) { processedCount++; updateButtonText(); continue; }
                const statusEl = previewItem.querySelector('.upload-status');
                try {
                    statusEl.textContent = '上传中...';
                    const formData = new FormData(); formData.append('image', item.file); formData.append('category', DOMElements.categorySelect.value); formData.append('description', item.description); formData.append('rename', item.shouldRename);
                    const response = await apiRequest('/api/admin/upload', { method: 'POST', body: formData });
                    const result = await response.json();
                    if (response.ok) { item.status = 'success'; previewItem.classList.add('upload-success'); statusEl.textContent = '✅ 上传成功'; } 
                    else { throw new Error(result.message || '上传失败'); }
                } catch (err) { if (err.message !== 'Unauthorized') { item.status = 'error'; statusEl.textContent = `❌ ${err.message}`; previewItem.classList.add('upload-error'); }
                } finally { processedCount++; updateButtonText(); }
            }
            
            showToast(`所有任务处理完成。`); DOMElements.uploadBtn.textContent = '上传文件'; 
            filesToUpload = [];
            DOMElements.imageInput.value = ''; 
            DOMElements.unifiedDescription.value = '';
            setTimeout(() => { DOMElements.filePreviewContainer.classList.add('hidden'); DOMElements.uploadBtn.disabled = true; }, 3000);
            await loadImages('all', '全部图片');
        };
        DOMElements.uploadForm.addEventListener('submit', processUploadQueue);

        async function refreshCategories() { const currentVal = DOMElements.categorySelect.value; await loadAndPopulateCategories(currentVal); await loadAndDisplayCategoriesForManagement(); }
        async function loadAndPopulateCategories(selectedCategory = null) { try { const response = await apiRequest('/api/categories'); const categories = await response.json(); [DOMElements.categorySelect, DOMElements.editCategorySelect].forEach(select => { const currentVal = select.value; select.innerHTML = ''; categories.forEach(cat => select.add(new Option(cat, cat))); select.value = categories.includes(currentVal) ? currentVal : selectedCategory || categories[0]; }); } catch (error) { if (error.message !== 'Unauthorized') console.error('加载分类失败:', error); } }
        async function loadAndDisplayCategoriesForManagement() { try { const response = await apiRequest('/api/categories'); const categories = await response.json(); DOMElements.categoryManagementList.innerHTML = ''; const allCatItem = document.createElement('div'); allCatItem.className = 'category-item flex items-center justify-between p-2 rounded cursor-pointer hover:bg-gray-100 active focus:outline-none focus:ring-0'; allCatItem.innerHTML = `<span class="category-name flex-grow">全部图片</span>`; DOMElements.categoryManagementList.appendChild(allCatItem); categories.forEach(cat => { const isUncategorized = cat === UNCATEGORIZED; const item = document.createElement('div'); item.className = 'category-item flex items-center justify-between p-2 rounded focus:outline-none focus:ring-0'; item.innerHTML = `<span class="category-name flex-grow ${isUncategorized ? 'text-slate-500' : 'cursor-pointer hover:bg-gray-100'}">${cat}</span>` + (isUncategorized ? '' : `<div class="space-x-2 flex-shrink-0"><button data-name="${cat}" class="rename-cat-btn text-blue-500 hover:text-blue-700 text-sm">重命名</button><button data-name="${cat}" class="delete-cat-btn text-red-500 hover:red-700 text-sm">删除</button></div>`); DOMElements.categoryManagementList.appendChild(item); }); } catch (error) { if (error.message !== 'Unauthorized') console.error('加载分类管理列表失败:', error); } }
        async function loadImages(category = 'all', categoryName = '全部图片') {
            DOMElements.imageList.innerHTML = ''; DOMElements.imageLoader.classList.remove('hidden');
            try {
                const url = `/api/images?category=${category}&search=${encodeURIComponent(currentSearchTerm)}&limit=1000`; // Load all for admin panel
                const response = await apiRequest(url); adminLoadedImages = (await response.json()).images;
                DOMElements.imageLoader.classList.add('hidden');
                const totalSize = adminLoadedImages.reduce((acc, img) => acc + (img.size || 0), 0);
                const titleText = currentSearchTerm ? `搜索 "${currentSearchTerm}" 的结果` : categoryName;
                DOMElements.imageListHeader.innerHTML = `${titleText} <span class="text-base text-gray-500 font-normal">(数量: ${adminLoadedImages.length} 张, 大小: ${formatBytes(totalSize)})</span>`;
                if (adminLoadedImages.length === 0) { DOMElements.imageList.innerHTML = '<p class="text-slate-500 col-span-full text-center">没有找到图片。</p>'; } 
                else { adminLoadedImages.forEach(renderImageCard); }
            } catch (error) { if(error.message !== 'Unauthorized') DOMElements.imageLoader.textContent = '加载图片失败。'; }
        }
        
        function renderImageCard(image) {
            const card = document.createElement('div');
            card.className = 'border rounded-lg shadow-sm bg-white overflow-hidden flex flex-col';
            card.innerHTML = `
                <a class="preview-btn h-40 bg-slate-100 flex items-center justify-center cursor-pointer group" data-id="${image.id}">
                    <img src="/image-proxy/${image.filename}?w=400" alt="${image.description}" class="max-h-full max-w-full object-contain group-hover:scale-105 transition-transform duration-300">
                </a>
                <div class="p-3 flex-grow flex flex-col">
                    <p class="font-bold text-sm truncate" title="${image.originalFilename}">${image.originalFilename}</p>
                    <p class="text-xs text-slate-500 -mt-1 mb-2">${formatBytes(image.size)}</p>
                    <p class="text-xs text-slate-500 mb-2">${image.category}</p>
                    <p class="text-xs text-slate-600 flex-grow mb-3 break-words">${image.description || '无描述'}</p>
                </div>
                <div class="bg-slate-50 p-2 flex justify-end items-center gap-1">
                    <button title="预览" data-id="${image.id}" class="preview-btn p-2 rounded-full text-slate-600 hover:bg-slate-200 hover:text-slate-800 transition-colors">
                        <svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor" class="w-5 h-5"><path stroke-linecap="round" stroke-linejoin="round" d="M2.036 12.322a1.012 1.012 0 010-.639C3.423 7.51 7.36 4.5 12 4.5c4.638 0 8.573 3.007 9.963 7.178.07.207.07.431 0 .639C20.577 16.49 16.64 19.5 12 19.5c-4.638 0-8.573-3.007-9.963-7.178z" /><path stroke-linecap="round" stroke-linejoin="round" d="M15 12a3 3 0 11-6 0 3 3 0 016 0z" /></svg>
                    </button>
                    <a href="${image.src}" download="${image.originalFilename}" title="下载" class="download-btn p-2 rounded-full text-slate-600 hover:bg-slate-200 hover:text-slate-800 transition-colors">
                        <svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor" class="w-5 h-5"><path stroke-linecap="round" stroke-linejoin="round" d="M3 16.5v2.25A2.25 2.25 0 005.25 21h13.5A2.25 2.25 0 0021 18.75V16.5M16.5 12L12 16.5m0 0L7.5 12m4.5 4.5V3" /></svg>
                    </a>
                    <button title="编辑" data-image='${JSON.stringify(image)}' class="edit-btn p-2 rounded-full text-slate-600 hover:bg-slate-200 hover:text-slate-800 transition-colors">
                        <svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor" class="w-5 h-5"><path stroke-linecap="round" stroke-linejoin="round" d="M16.862 4.487l1.687-1.688a1.875 1.875 0 112.652 2.652L6.832 19.82a4.5 4.5 0 01-1.897 1.13l-2.685.8.8-2.685a4.5 4.5 0 011.13-1.897L16.863 4.487zm0 0L19.5 7.125" /></svg>
                    </button>
                    <button title="删除" data-id="${image.id}" class="delete-btn p-2 rounded-full text-red-500 hover:bg-red-100 hover:text-red-700 transition-colors">
                        <svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor" class="w-5 h-5"><path stroke-linecap="round" stroke-linejoin="round" d="M14.74 9l-.346 9m-4.788 0L9.26 9m9.968-3.21c.342.052.682.107 1.022.166m-1.022-.165L18.16 19.673a2.25 2.25 0 01-2.244 2.077H8.084a2.25 2.25 0 01-2.244-2.077L4.772 5.79m14.456 0a48.108 48.108 0 00-3.478-.397m-12 .562c.34-.059.68-.114 1.022-.165m0 0a48.11 48.11 0 013.478-.397m7.5 0v-.916c0-1.18-.91-2.134-2.036-2.134H8.718c-1.126 0-2.037.955-2.037 2.134v.916m7.5 0a48.667 48.667 0 00-7.5 0" /></svg>
                    </button>
                </div>
            `;
            DOMElements.imageList.appendChild(card);
        }

        function updateAdminLightbox() { const item = adminLoadedImages[currentAdminLightboxIndex]; if (!item) return; const lightbox = DOMElements.adminLightbox; lightbox.querySelector('.lightbox-image').src = item.src; lightbox.querySelector('#admin-lightbox-download-link').href = item.src; lightbox.querySelector('#admin-lightbox-download-link').download = item.originalFilename; }
        function showNextAdminImage() { currentAdminLightboxIndex = (currentAdminLightboxIndex + 1) % adminLoadedImages.length; updateAdminLightbox(); }
        function showPrevAdminImage() { currentAdminLightboxIndex = (currentAdminLightboxIndex - 1 + adminLoadedImages.length) % adminLoadedImages.length; updateAdminLightbox(); }
        function closeAdminLightbox() { DOMElements.adminLightbox.classList.remove('active'); document.body.classList.remove('lightbox-open'); }
        DOMElements.adminLightbox.addEventListener('click', e => { if (e.target.matches('.lb-next')) showNextAdminImage(); else if (e.target.matches('.lb-prev')) showPrevAdminImage(); else if (e.target.matches('.lb-close') || e.target === DOMElements.adminLightbox) closeAdminLightbox(); });
        document.addEventListener('keydown', e => { if (DOMElements.adminLightbox.classList.contains('active')) { if (e.key === 'ArrowRight') showNextAdminImage(); if (e.key === 'ArrowLeft') showPrevAdminImage(); if (e.key === 'Escape') closeAdminLightbox(); } });
        DOMElements.addCategoryBtn.addEventListener('click', () => { showGenericModal('添加新分类', '<form id="modal-form"><input type="text" id="modal-input" placeholder="输入新分类的名称" required class="w-full border rounded px-3 py-2"></form>', '<button type="button" class="modal-cancel-btn bg-gray-300 hover:bg-gray-400 text-black py-2 px-4 rounded">取消</button><button type="submit" form="modal-form" class="bg-green-600 hover:bg-green-700 text-white py-2 px-4 rounded">保存</button>'); document.getElementById('modal-form').onsubmit = async (e) => { e.preventDefault(); const newName = document.getElementById('modal-input').value.trim(); if (!newName) return; try { const response = await apiRequest('/api/admin/categories', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ name: newName }) }); if (!response.ok) throw new Error((await response.json()).message); hideModal(DOMElements.genericModal); showToast('分类创建成功'); await refreshCategories(); } catch (error) { showToast(`添加失败: ${error.message}`, 'error'); } }; });
        DOMElements.categoryManagementList.addEventListener('click', async (e) => {
            const target = e.target; const catName = target.dataset.name;
            if (target.classList.contains('rename-cat-btn')) {
                showGenericModal(`重命名分类 "${catName}"`, '<form id="modal-form"><input type="text" id="modal-input" required class="w-full border rounded px-3 py-2"></form>', '<button type="button" class="modal-cancel-btn bg-gray-300 hover:bg-gray-400 text-black py-2 px-4 rounded">取消</button><button type="submit" form="modal-form" class="bg-blue-600 hover:bg-blue-700 text-white py-2 px-4 rounded">保存</button>');
                const input = document.getElementById('modal-input'); input.value = catName;
                document.getElementById('modal-form').onsubmit = async (ev) => { ev.preventDefault(); const newName = input.value.trim(); if (!newName || newName === catName) { hideModal(DOMElements.genericModal); return; } try { const response = await apiRequest('/api/admin/categories', { method: 'PUT', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ oldName: catName, newName }) }); if (!response.ok) throw new Error((await response.json()).message); hideModal(DOMElements.genericModal); showToast('重命名成功'); await Promise.all([refreshCategories(), loadImages('all', '全部图片')]); } catch (error) { showToast(`重命名失败: ${error.message}`, 'error'); } };
            } else if (target.classList.contains('delete-cat-btn')) {
                const confirmed = await showConfirmationModal('确认删除', `<p>确定要删除分类 "<strong>${catName}</strong>" 吗？<br>此分类下的图片将归入 "未分类"。</p>`, '确认删除');
                if(confirmed) { try { const response = await apiRequest('/api/admin/categories', { method: 'DELETE', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ name: catName }) }); if (!response.ok) throw new Error((await response.json()).message); showToast('删除成功'); await Promise.all([refreshCategories(), loadImages('all', '全部图片')]); } catch (error) { showToast(`删除失败: ${error.message}`, 'error'); } }
            } else if (target.closest('.category-item')) {
                document.querySelectorAll('.category-item').forEach(el => el.classList.remove('active'));
                const parentItem = target.closest('.category-item');
                parentItem.classList.add('active');
                DOMElements.searchInput.value = ''; currentSearchTerm = '';
                const category = parentItem.querySelector('.category-name').textContent; await loadImages(category === '全部图片' ? 'all' : category, category);
            }
        });
        DOMElements.searchInput.addEventListener('input', () => { clearTimeout(debounceTimer); debounceTimer = setTimeout(() => { currentSearchTerm = DOMElements.searchInput.value; document.querySelectorAll('.category-item').forEach(el => el.classList.remove('active')); DOMElements.categoryManagementList.firstElementChild.classList.add('active'); loadImages('all', '全部图片'); }, 300); });
        DOMElements.imageList.addEventListener('click', async (e) => {
            const target = e.target.closest('button, a'); if (!target) return;
            if (target.matches('.preview-btn')) { const imageId = target.dataset.id; currentAdminLightboxIndex = adminLoadedImages.findIndex(img => img.id === imageId); if (currentAdminLightboxIndex === -1) return; updateAdminLightbox(); DOMElements.adminLightbox.classList.add('active'); document.body.classList.add('lightbox-open');
            } else if (target.matches('.edit-btn')) {
                const image = JSON.parse(target.dataset.image); await loadAndPopulateCategories(image.category);
                document.getElementById('edit-id').value = image.id; document.getElementById('edit-originalFilename').value = image.originalFilename; document.getElementById('edit-description').value = image.description;
                DOMElements.editImageModal.classList.add('active');
            } else if (target.matches('.delete-btn')) {
                const imageId = target.dataset.id;
                const confirmed = await showConfirmationModal('确认删除', `<p>确定要永久删除这张图片吗？此操作无法撤销。</p>`, '确认删除');
                if(confirmed) { try { const response = await apiRequest(`/api/admin/images/${imageId}`, { method: 'DELETE' }); if (!response.ok) throw new Error('删除失败'); showToast('图片已删除'); const activeCatItem = document.querySelector('.category-item.active .category-name'); const activeCat = activeCatItem ? activeCatItem.textContent : '全部图片'; await loadImages(activeCat === '全部图片' ? 'all' : activeCat, activeCat); } catch (error) { showToast(error.message, 'error'); } }
            }
        });
        DOMElements.editImageForm.addEventListener('submit', async (e) => {
            e.preventDefault(); const id = document.getElementById('edit-id').value;
            const body = JSON.stringify({ originalFilename: document.getElementById('edit-originalFilename').value, category: DOMElements.editCategorySelect.value, description: document.getElementById('edit-description').value });
            try { const response = await apiRequest(`/api/admin/images/${id}`, { method: 'PUT', headers: { 'Content-Type': 'application/json' }, body }); if (!response.ok) throw new Error((await response.json()).message); hideModal(DOMElements.editImageModal); showToast('更新成功'); const activeCatItem = document.querySelector('.category-item.active .category-name'); const activeCat = activeCatItem ? activeCatItem.textContent : '全部图片'; await loadImages(activeCat === '全部图片' ? 'all' : activeCat, activeCat); } catch (error) { showToast(`更新失败: ${error.message}`, 'error'); }
        });
        [DOMElements.genericModal, DOMElements.editImageModal].forEach(modal => { const cancelBtn = modal.querySelector('.modal-cancel-btn'); if(cancelBtn) { cancelBtn.addEventListener('click', () => hideModal(modal)); } modal.addEventListener('click', (e) => { if (e.target === modal) hideModal(modal); }); });
        async function init() { await Promise.all([ refreshCategories(), loadImages('all', '全部图片') ]); }
        init();
    });
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
        if ss -Hltn | awk '{print $4}' | grep -q ":${port}$"; then
            return 1 # 被占用
        fi
    elif command -v netstat &>/dev/null; then
        if netstat -lnt | awk '{print $4}' | grep -q ":${port}$"; then
            return 1 # 被占用
        fi
    else
        echo -e "${YELLOW}警告: 无法找到 ss 或 netstat 命令，跳过端口检查。${NC}"
    fi
    return 0 # 未被占用
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
        
        if command -v pm2 &> /dev/null && pm2 id "$APP_NAME" &> /dev/null; then
            local pm2_status; pm2_status=$(pm2 show "$APP_NAME" | grep 'status' | awk '{print $4}')
            [ "$pm2_status" == "online" ] && printf "  %-15s %b%s%b\n" "运行状态:" "${GREEN}" "在线 (Online)" "${NC}" || printf "  %-15s %b%s%b\n" "运行状态:" "${RED}" "离线 (Offline)" "${NC}"
            local log_path; log_path=$(pm2 show "$APP_NAME" | grep 'out log path' | awk '{print $6}')
            printf "  %-15s %b%s%b\n" "日志文件:" "${BLUE}" "${log_path}" "${NC}"
        else
            printf "  %-15s %b%s%b\n" "运行状态:" "${YELLOW}" "未知 (PM2未运行或应用未被管理)" "${NC}"
        fi
        
        printf "  %-15s %bhttp://%s:%s%b\n" "前台画廊:" "${GREEN}" "${SERVER_IP}" "${PORT}" "${NC}"
        printf "  %-15s %bhttp://%s:%s/admin%b\n" "后台管理:" "${GREEN}" "${SERVER_IP}" "${PORT}" "${NC}"
        printf "  %-15s %b%s%b\n" "后台用户:" "${BLUE}" "${ADMIN_USER}" "${NC}"
        cd - >/dev/null 2>&1
    else
        printf "  %-15s %b%s%b\n" "安装状态:" "${RED}" "未安装" "${NC}"
    fi
    echo -e "${YELLOW}==============================================================${NC}"
}

install_app() {
    echo -e "${GREEN}--- 1. 开始安装或修复应用 ---${NC}"
    echo "--> 正在检查系统环境和权限..."
    
    local sudo_cmd=""
    if [ "$EUID" -ne 0 ]; then
        if command -v sudo &> /dev/null; then
            sudo_cmd="sudo"; echo -e "${GREEN}--> 检测到 sudo，将使用 sudo 执行需要权限的命令。${NC}"
        else
            echo -e "${RED}错误：此脚本需要以 root 用户身份运行，或者需要安装 'sudo' 工具才能继续。${NC}"; return 1
        fi
    else echo -e "${GREEN}--> 检测到以 root 用户身份运行。${NC}"; fi

    check_and_install_deps "Node.js & npm" "nodejs npm" "node" "${sudo_cmd}" || return 1
    check_and_install_deps "编译工具(for sharp)" "build-essential" "make" "${sudo_cmd}" || return 1

    echo -e "${YELLOW}--> 正在检查 PM2...${NC}"
    if ! command -v pm2 &> /dev/null; then
        echo -e "${YELLOW}--> 检测到 PM2 未安装，将通过 npm 全局安装...${NC}"
        if ${sudo_cmd} npm install -g pm2; then echo -e "${GREEN}--> PM2 安装成功！${NC}";
        else echo -e "${RED}--> PM2 安装失败，请检查 npm 是否配置正确。${NC}"; return 1; fi
    else echo -e "${GREEN}--> PM2 已安装。${NC}"; fi

    echo -e "${GREEN}--> 所有核心依赖均已满足。${NC}"
    generate_files || return 1
    
    cd "${INSTALL_DIR}" || { echo -e "${RED}错误: 无法进入安装目录 '${INSTALL_DIR}'。${NC}"; return 1; }

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
    echo -e "${GREEN}--> .env 配置文件创建成功！默认端口为 3000。${NC}"
    
    echo -e "${YELLOW}--> 正在安装项目依赖 (npm install)，这可能需要几分钟，请耐心等待...${NC}"
    if npm install; then echo -e "${GREEN}--> 项目依赖安装成功！${NC}";
    else echo -e "${RED}--> npm install 失败，请检查错误日志。${NC}"; return 1; fi

    echo -e "${GREEN}--- 安装完成！正在自动启动应用... ---${NC}"; start_app
}

start_app() {
    echo -e "${GREEN}--- 正在启动应用... ---${NC}"
    [ ! -d "${INSTALL_DIR}" ] || [ ! -f "${INSTALL_DIR}/.env" ] && { echo -e "${RED}错误: 应用未安装或 .env 文件不存在。请先运行安装程序 (选项1)。${NC}"; return 1; }
    cd "${INSTALL_DIR}" || return 1
    
    local PORT; PORT=$(grep 'PORT=' .env | cut -d '=' -f2)
    if ! check_port "$PORT"; then
        echo -e "${RED}错误: 端口 ${PORT} 已被占用！请使用菜单中的“修改端口号”功能更换一个端口。${NC}"; return 1
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
    [ ! -d "${INSTALL_DIR}" ] && { echo -e "${RED}错误: 应用未安装。${NC}"; return 1; }
    cd "${INSTALL_DIR}" || return 1
    local PORT; PORT=$(grep 'PORT=' .env | cut -d '=' -f2)
    if ! check_port "$PORT"; then
        echo -e "${RED}错误: 端口 ${PORT} 已被占用！无法重启。请先解决端口冲突。${NC}"; return 1
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
    [ ! -d "${INSTALL_DIR}" ] || [ ! -f "${INSTALL_DIR}/.env" ] && { echo -e "${RED}错误: 应用未安装。${NC}"; return 1; }
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
    [ ! -d "${INSTALL_DIR}" ] || [ ! -f "${INSTALL_DIR}/.env" ] && { echo -e "${RED}错误: 应用未安装。${NC}"; return 1; }
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

backup_app() {
    echo -e "${YELLOW}--- 正在备份应用数据... ---${NC}"
    [ ! -d "${INSTALL_DIR}" ] && { echo -e "${RED}错误: 应用未安装，无法备份。${NC}"; return 1; }
    
    mkdir -p "${BACKUP_DIR}"
    local backup_filename="backup-$(date +%Y%m%d-%H%M%S).tar.gz"
    local backup_filepath="${BACKUP_DIR}/${backup_filename}"
    
    echo "--> 目标文件: ${backup_filepath}"
    if tar -czf "${backup_filepath}" -C "${INSTALL_DIR}" public/uploads data; then
        echo -e "${GREEN}--- 备份成功！文件已保存至: ${backup_filepath} ---${NC}"
    else
        echo -e "${RED}--- 备份失败！请检查权限和可用空间。 ---${NC}"
    fi
}

restore_app() {
    echo -e "${YELLOW}--- 从备份恢复应用数据 ---${NC}"
    [ ! -d "${INSTALL_DIR}" ] && { echo -e "${RED}错误: 应用未安装，无法恢复。${NC}"; return 1; }
    [ ! -d "${BACKUP_DIR}" ] || [ -z "$(ls -A ${BACKUP_DIR}/*.tar.gz 2>/dev/null)" ] && { echo -e "${RED}错误: 未找到任何备份文件。请先执行备份操作。${NC}"; return 1; }

    echo "可用备份文件列表:"
    select backup_file in "${BACKUP_DIR}"/*.tar.gz; do
        [ -n "$backup_file" ] && break || { echo -e "${RED}无效选择，请重试。${NC}"; continue; }
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
        echo -e "${RED}--- 恢复失败！请检查备份文件是否完整以及目录权限。 ---${NC}"
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
        echo -e "${GREEN}应用已彻底卸载。所有相关文件和进程已被移除。${NC}"
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
    printf "   %-3s %s\n" "9." "${GREEN}备份应用数据${NC}"
    printf "   %-3s %s\n" "10." "${YELLOW}从备份恢复数据${NC}"
    echo ""
    echo -e " ${YELLOW}【危险操作】${NC}"
    printf "   %-3s %b%s%b\n" "11." "${RED}" "彻底卸载应用" "${NC}"
    echo ""
    printf "   %-3s %s\n" "0." "退出脚本"
    echo -e "${YELLOW}--------------------------------------------------------------${NC}"
}

main_loop() {
    local choice
    read -p "请输入你的选择 [0-11]: " choice
    
    case $choice in
        1) install_app ;;
        2) start_app ;;
        3) stop_app ;;
        4) restart_app ;;
        5) ;; # 刷新状态，直接循环即可
        6) view_logs ;;
        7) manage_credentials ;;
        8) manage_port ;;
        9) backup_app ;;
        10) restore_app ;;
        11) uninstall_app ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效输入...${NC}" ;;
    esac

    if [[ "$choice" != "0" ]]; then
        read -n 1 -s -r -p "按任意键返回主菜单..."
    fi
}

# --- 脚本主入口 ---
while true; do
    show_menu
    main_loop
done
