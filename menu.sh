#!/bin/bash

# =================================================================
#   图片画廊 专业版 - 一体化部署与管理脚本 (v0.5.0 核心重构)
#
#   作者: 编码助手 (经 Gemini Pro 优化)
#   v0.5.0 更新:
#   - 重大重构 (后台): 彻底重构后台图片列表的事件处理模型，由统一的委托事件改为在元素创建时独立绑定，从根本上解决了预览、下载、删除等按钮“无响应”的连锁BUG。
#   - 健壮性 (后台): 新的事件模型使代码更清晰、更稳定，且易于维护，恢复了所有按钮的正常功能。
# =================================================================

# --- 配置 ---
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color
PROMPT_Y="(${GREEN}y${NC}/${RED}n${NC})"

SCRIPT_VERSION="0.5.0"
APP_NAME="image-gallery"

# --- 路径设置 ---
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
INSTALL_DIR="${SCRIPT_DIR}/image-gallery-app"
BACKUP_DIR="${SCRIPT_DIR}/backups"


# --- 核心功能：文件生成 ---
generate_files() {
    echo "--> 正在创建安装目录: ${INSTALL_DIR}"
    mkdir -p "${INSTALL_DIR}/public"
    cd "${INSTALL_DIR}" || { echo -e "${RED}错误: 无法进入新创建的安装目录。${NC}"; return 1; }

    # 调用覆盖文件函数
    overwrite_app_files
}

overwrite_app_files() {
    # 此函数只覆盖应用逻辑文件，不触及数据和配置
    echo "--> 正在覆盖更新核心应用文件..."

    echo "--> 正在生成 package.json..."
cat << 'EOF' > package.json
{
  "name": "image-gallery-pro",
  "version": "0.5.0",
  "description": "A high-performance, full-stack image gallery application with all features.",
  "main": "server.js",
  "scripts": {
    "start": "node server.js"
  },
  "dependencies": {
    "body-parser": "^1.19.0",
    "cookie-parser": "^1.4.6",
    "dotenv": "^16.0.0",
    "express": "^4.17.1",
    "jsonwebtoken": "^8.5.1",
    "multer": "^1.4.4",
    "qrcode": "^1.5.3",
    "sharp": "^0.33.1",
    "speakeasy": "^2.0.0",
    "uuid": "^8.3.2"
  }
}
EOF

    echo "--> 正在生成后端服务器 server.js..."
cat << 'EOF' > server.js
const express = require('express');
const multer = require('multer');
const bodyParser = require('body-parser');
const path = require('path');
const fs = require('fs').promises;
const { v4: uuidv4 } = require('uuid');
const cookieParser = require('cookie-parser');
const jwt = require('jsonwebtoken');
const sharp = require('sharp');
const speakeasy = require('speakeasy');
const qrcode = require('qrcode');
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
const configPath = path.join(__dirname, 'data', 'config.json');
const uploadsDir = path.join(__dirname, 'public', 'uploads');
const cacheDir = path.join(__dirname, 'public', 'cache');

let appConfig = {};

const initializeApp = async () => {
    try {
        await fs.mkdir(path.join(__dirname, 'data'), { recursive: true });
        await fs.mkdir(uploadsDir, { recursive: true });
        await fs.mkdir(cacheDir, { recursive: true });
        appConfig = await readDB(configPath, {});
    } catch (error) { console.error('初始化失败:', error); process.exit(1); }
};

app.use(bodyParser.json());
app.use(bodyParser.urlencoded({ extended: true }));
app.use(cookieParser());

const readDB = async (filePath, defaultVal = []) => {
    try { await fs.access(filePath); const data = await fs.readFile(filePath, 'utf-8'); return data.trim() === '' ? defaultVal : JSON.parse(data); } 
    catch (error) { if (error.code === 'ENOENT') return defaultVal; throw new Error(`读取DB时出错: ${error.message}`); }
};
const writeDB = async (filePath, data) => {
    try { await fs.writeFile(filePath, JSON.stringify(data, null, 2)); } 
    catch (error) { throw new Error(`写入DB时出错: ${error.message}`); }
};

const authMiddleware = (isApi) => (req, res, next) => {
    const token = req.cookies[AUTH_TOKEN_NAME];
    if (!token) { return isApi ? res.status(401).json({ message: '认证失败' }) : res.redirect('/login.html'); }
    try { jwt.verify(token, JWT_SECRET); next(); } 
    catch (err) { return isApi ? res.status(401).json({ message: '认证令牌无效或已过期' }) : res.redirect('/login.html'); }
};
const requirePageAuth = authMiddleware(false);
const requireApiAuth = authMiddleware(true);

const handleApiError = (handler) => async (req, res, next) => {
    try {
        await handler(req, res, next);
    } catch (error) {
        console.error(`API Error on ${req.method} ${req.path}:`, error);
        res.status(500).json({ message: error.message || '服务器发生未知错误。' });
    }
};

app.get('/api/2fa/is-enabled', handleApiError(async (req, res) => {
    const currentConfig = await readDB(configPath, {});
    const isEnabled = !!(currentConfig.tfa && currentConfig.tfa.secret);
    res.json({ enabled: isEnabled });
}));

app.post('/api/login', handleApiError(async (req, res) => {
    const { username, password, tfa_token } = req.body;
    if (username !== ADMIN_USERNAME || password !== ADMIN_PASSWORD) {
        return res.redirect('/login.html?error=1');
    }
    
    appConfig = await readDB(configPath, {});
    if (appConfig.tfa && appConfig.tfa.secret) {
        if (!tfa_token) {
             return res.redirect('/login.html?error=2'); 
        }
        const verified = speakeasy.totp.verify({
            secret: appConfig.tfa.secret,
            encoding: 'base32',
            token: tfa_token,
        });
        if (!verified) {
            return res.redirect('/login.html?error=3'); 
        }
    }

    const token = jwt.sign({ username }, JWT_SECRET, { expiresIn: '1d' });
    res.cookie(AUTH_TOKEN_NAME, token, { httpOnly: true, secure: process.env.NODE_ENV === 'production', maxAge: 86400000 });
    res.redirect('/admin.html');
}));

app.get('/api/logout', (req, res) => { res.clearCookie(AUTH_TOKEN_NAME); res.redirect('/login.html'); });
app.get('/admin.html', requirePageAuth, (req, res) => res.sendFile(path.join(__dirname, 'public', 'admin.html')));
app.get('/admin', requirePageAuth, (req, res) => res.redirect('/admin.html'));

app.get('/api/images', handleApiError(async (req, res) => {
    let images = await readDB(dbPath);
    images = images.filter(img => img.status !== 'deleted');
    
    const { category, search, page = 1, limit = 20 } = req.query;

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
    const totalPages = Math.ceil(totalImages / limitNum);

    res.json({
        images: paginatedImages,
        page: pageNum,
        limit: limitNum,
        totalPages: totalPages,
        totalImages: totalImages,
        hasMore: pageNum < totalPages
    });
}));

app.get('/api/categories', handleApiError(async (req, res) => {
    const categories = await readDB(categoriesPath, [UNCATEGORIZED]);
    if (!categories.includes(UNCATEGORIZED)) {
        categories.unshift(UNCATEGORIZED);
    }
    res.json(categories.sort((a,b) => a === UNCATEGORIZED ? -1 : b === UNCATEGORIZED ? 1 : a.localeCompare(b, 'zh-CN')));
}));

app.get('/api/public/categories', handleApiError(async (req, res) => {
    const allDefinedCategories = await readDB(categoriesPath, [UNCATEGORIZED]);
    let images = await readDB(dbPath);
    images = images.filter(img => img.status !== 'deleted');
    const categoriesInUse = new Set(images.map(img => img.category || UNCATEGORIZED));
    if (!allDefinedCategories.includes(UNCATEGORIZED)) {
        allDefinedCategories.unshift(UNCATEGORIZED);
    }
    let categoriesToShow = allDefinedCategories.filter(cat => categoriesInUse.has(cat));
    res.json(categoriesToShow.sort((a,b) => a === UNCATEGORIZED ? -1 : b === UNCATEGORIZED ? 1 : a.localeCompare(b, 'zh-CN')));
}));

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

apiAdminRouter.post('/check-filenames', handleApiError(async(req, res) => {
    const { filenames } = req.body;
    if (!Array.isArray(filenames)) { return res.status(400).json({message: '无效的输入格式。'}); }
    const images = await readDB(dbPath);
    const existingFilenames = new Set(images.filter(img => img.status !== 'deleted').map(img => img.originalFilename));
    const duplicates = filenames.filter(name => existingFilenames.has(name));
    res.json({ duplicates });
}));

apiAdminRouter.post('/upload', upload.single('image'), handleApiError(async (req, res) => {
    if (!req.file) return res.status(400).json({ message: '没有选择文件。' });
    const metadata = await sharp(req.file.path).metadata();
    const images = await readDB(dbPath);
    
    let originalFilename = req.file.originalname;
    const existingFilenames = new Set(images.filter(img => img.status !== 'deleted').map(img => img.originalFilename));
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
}));

apiAdminRouter.delete('/images/:id', handleApiError(async (req, res) => {
    let images = await readDB(dbPath);
    const imageIndex = images.findIndex(img => img.id === req.params.id);
    if (imageIndex === -1) return res.status(404).json({ message: '图片未找到' });
    images[imageIndex].status = 'deleted';
    images[imageIndex].deletedAt = new Date().toISOString();
    await writeDB(dbPath, images);
    res.json({ message: '图片已移至回收站' });
}));

apiAdminRouter.put('/images/:id', handleApiError(async (req, res) => {
    let images = await readDB(dbPath);
    const { category, description, originalFilename } = req.body;
    const imageIndex = images.findIndex(img => img.id === req.params.id);
    if (imageIndex === -1) return res.status(404).json({ message: '图片未找到' });
    const imageToUpdate = { ...images[imageIndex] };
    imageToUpdate.category = category || imageToUpdate.category;
    imageToUpdate.description = description === undefined ? imageToUpdate.description : description;
    if (originalFilename && originalFilename !== imageToUpdate.originalFilename) {
        const existingFilenames = new Set(images.filter(img => img.status !== 'deleted').map(img => img.originalFilename).filter(name => name !== images[imageIndex].originalFilename));
        if (existingFilenames.has(originalFilename)) { return res.status(409).json({ message: '该文件名已存在。'}); }
        imageToUpdate.originalFilename = originalFilename;
    }
    images[imageIndex] = imageToUpdate;
    await writeDB(dbPath, images);
    res.json({ message: '更新成功', image: imageToUpdate });
}));

apiAdminRouter.post('/categories', handleApiError(async (req, res) => {
    const { name } = req.body;
    if (!name || name.trim() === '') return res.status(400).json({ message: '分类名称不能为空。' });
    let categories = await readDB(categoriesPath, [UNCATEGORIZED]);
    if (categories.includes(name)) return res.status(409).json({ message: '该分类已存在。' });
    categories.push(name);
    await writeDB(categoriesPath, categories);
    res.status(201).json({ message: '分类创建成功', category: name });
}));

apiAdminRouter.delete('/categories', handleApiError(async (req, res) => {
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
}));

apiAdminRouter.put('/categories', handleApiError(async (req, res) => {
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
}));

apiAdminRouter.get('/recycle-bin', handleApiError(async (req, res) => {
    const { search, page = 1, limit = 12 } = req.query;
    let images = await readDB(dbPath);
    let deletedImages = images.filter(img => img.status === 'deleted');

    if (search) {
        const searchTerm = search.toLowerCase();
        deletedImages = deletedImages.filter(img => (img.originalFilename && img.originalFilename.toLowerCase().includes(searchTerm)) || (img.description && img.description.toLowerCase().includes(searchTerm)));
    }
    
    deletedImages.sort((a, b) => new Date(b.deletedAt) - new Date(a.deletedAt));

    const pageNum = parseInt(page);
    const limitNum = parseInt(limit);
    const startIndex = (pageNum - 1) * limitNum;
    const endIndex = pageNum * limitNum;
    
    const paginatedImages = deletedImages.slice(startIndex, endIndex);
    const totalImages = deletedImages.length;

    res.json({
        images: paginatedImages,
        page: pageNum,
        totalPages: Math.ceil(totalImages / limitNum)
    });
}));

apiAdminRouter.post('/recycle-bin/:id/restore', handleApiError(async (req, res) => {
    let images = await readDB(dbPath);
    const imageIndex = images.findIndex(img => img.id === req.params.id);
    if (imageIndex === -1) return res.status(404).json({ message: '图片未找到' });
    delete images[imageIndex].status;
    delete images[imageIndex].deletedAt;
    await writeDB(dbPath, images);
    res.json({ message: '图片已成功恢复' });
}));

apiAdminRouter.delete('/recycle-bin/:id/purge', handleApiError(async (req, res) => {
    let images = await readDB(dbPath);
    const imageToDelete = images.find(img => img.id === req.params.id);
    if (!imageToDelete) return res.status(404).json({ message: '图片未找到' });
    
    const filePath = path.join(uploadsDir, imageToDelete.filename);
    try { await fs.unlink(filePath); } catch (error) { console.error(`删除文件失败: ${filePath}`, error); }
    
    const updatedImages = images.filter(img => img.id !== req.params.id);
    await writeDB(dbPath, updatedImages);
    res.json({ message: '图片已永久删除' });
}));

apiAdminRouter.get('/2fa/status', handleApiError(async(req, res) => {
    appConfig = await readDB(configPath, {});
    res.json({ enabled: !!(appConfig.tfa && appConfig.tfa.secret) });
}));

apiAdminRouter.post('/2fa/generate', handleApiError((req, res) => {
    const secret = speakeasy.generateSecret({ name: `ImageGallery (${ADMIN_USERNAME})` });
    qrcode.toDataURL(secret.otpauth_url, (err, data_url) => {
        if (err) return res.status(500).json({ message: '无法生成QR码' });
        res.json({ secret: secret.base32, qrCode: data_url });
    });
}));

apiAdminRouter.post('/2fa/enable', handleApiError(async (req, res) => {
    const { secret, token } = req.body;
    const verified = speakeasy.totp.verify({ secret, encoding: 'base32', token });

    if (verified) {
        appConfig.tfa = { secret: secret };
        await writeDB(configPath, appConfig);
        res.json({ message: '2FA 已成功启用！' });
    } else {
        res.status(400).json({ message: '验证码不正确。' });
    }
}));

apiAdminRouter.post('/2fa/disable', handleApiError(async (req, res) => {
    appConfig = await readDB(configPath, {});
    delete appConfig.tfa;
    await writeDB(configPath, appConfig);
    res.json({ message: '2FA 已禁用。' });
}));


app.use('/api/admin', apiAdminRouter);
app.use(express.static(path.join(__dirname, 'public')));
(async () => {
    if (!JWT_SECRET) { console.error(`错误: JWT_SECRET 未在 .env 文件中设置。`); process.exit(1); }
    await initializeApp();
    app.listen(PORT, () => console.log(`服务器正在 http://localhost:${PORT} 运行`));
})();
EOF

    echo "--> 正在生成主画廊 public/index.html (v0.5.0)..."
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
    <script src="https://unpkg.com/masonry-layout@4/dist/masonry.pkgd.min.js"></script>
    <script src="https://unpkg.com/imagesloaded@5/imagesloaded.pkgd.min.js"></script>

    <style>
        :root {
            --bg-color: #f0fdf4; --text-color: #14532d; --header-bg: rgba(240, 253, 244, 0.85);
            --filter-btn-color: #166534; --filter-btn-hover-bg: #dcfce7; --filter-btn-active-bg: #22c55e;
            --filter-btn-active-border: #16a34a; --grid-item-bg: #e4e4e7; --shimmer-color: #ffffff4d;
            --search-bg: #ffffff; --search-placeholder-color: #9ca3af; --divider-color: #dcfce7;
            --spinner-base-color: #ffffff4d; --spinner-top-color: #ffffffbf;
        }
        body.dark {
            --bg-color: #111827; --text-color: #a7f3d0; --header-bg: rgba(17, 24, 39, 0.85);
            --filter-btn-color: #a7f3d0; --filter-btn-hover-bg: #1f2937; --filter-btn-active-bg: #16a34a;
            --filter-btn-active-border: #15803d; --grid-item-bg: #374151; --shimmer-color: #ffffff1a;
            --search-bg: #1f2937; --search-placeholder-color: #6b7280; --divider-color: #166534;
            --spinner-base-color: #0000004d; --spinner-top-color: #ffffff80;
        }
        
        html { height: 100%; scroll-behavior: smooth; }
        body { font-family: 'Inter', 'Noto Sans SC', sans-serif; background-color: var(--bg-color); color: var(--text-color); display: flex; flex-direction: column; min-height: 100%; }
        main { flex-grow: 1; }
        body.overflow-hidden { overflow: hidden; }

        .header-sticky { background-color: var(--header-bg); backdrop-filter: blur(8px); position: sticky; top: 0; z-index: 40; box-shadow: 0 1px 3px 0 rgb(0 0 0 / 0.1), 0 1px 2px -1px rgb(0 0 0 / 0.1); transition: transform 0.3s ease-in-out; will-change: transform; }
        .header-sticky.is-hidden { transform: translateY(-100%); }
        
        #search-overlay { opacity: 0; visibility: hidden; transition: opacity 0.3s ease, visibility 0s 0.3s; background-color: transparent; }
        #search-overlay.active { opacity: 1; visibility: visible; transition: opacity 0.3s ease, visibility 0s 0s; }
        #search-box { transform: translateY(-20px) scale(0.98); opacity: 0; transition: transform 0.3s ease, opacity 0.3s ease; background-color: var(--search-bg); color: var(--text-color); box-shadow: 0 10px 15px -3px rgb(0 0 0 / 0.1), 0 4px 6px -4px rgb(0 0 0 / 0.1); }
        #search-overlay.active #search-box { transform: translateY(0) scale(1); opacity: 1; }
        #search-input:focus { outline: none; }
        
        .grid-item {
            width: 48%;
            margin-bottom: 1rem;
            float: left;
        }
        .grid-item.grid-item--width2 {
            width: 98%;
        }
        @media (min-width: 640px) {
            .grid-item { width: 32%; } 
            .grid-item.grid-item--width2 { width: 65.3%; }
        } 
        @media (min-width: 768px) {
            .grid-item { width: 24%; }
            .grid-item.grid-item--width2 { width: 49%; }
        } 
        @media (min-width: 1024px) {
            .grid-item { width: 19%; }
            .grid-item.grid-item--width2 { width: 39%; }
        } 
        @media (min-width: 1280px) {
            .grid-item { width: 15.8%; }
            .grid-item.grid-item--width2 { width: 32.6%; }
        }

        .grid-item > a { display: block; border-radius: 0.5rem; overflow: hidden; cursor: pointer; text-decoration: none; }
        
        .image-placeholder { position: relative; width: 100%; background-color: var(--grid-item-bg); border-radius: 0.5rem; overflow: hidden; }
        .image-placeholder::after { content: ''; position: absolute; top: 0; left: 0; width: 100%; height: 100%; background: linear-gradient(100deg, transparent 20%, var(--shimmer-color) 50%, transparent 80%); animation: shimmer 1.5s infinite linear; background-size: 200% 100%; }
        @keyframes shimmer { 0% { background-position: 200% 0; } 100% { background-position: -200% 0; } }
        .image-placeholder.item-loaded::after { display: none; }

        .spinner { position: absolute; top: 50%; left: 50%; width: 2.5rem; height: 2.5rem; margin-top: -1.25rem; margin-left: -1.25rem; border: 4px solid var(--spinner-base-color); border-top-color: var(--spinner-top-color); border-radius: 50%; animation: spin 1s linear infinite; transition: opacity 0.3s; z-index: 1; }
        @keyframes spin { to { transform: rotate(360deg); } }
        .image-placeholder.item-loaded .spinner { opacity: 0; }

        .image-placeholder img { display: block; width: 100%; height: auto; opacity: 0; transition: opacity 0.4s ease-in-out; }
        .image-placeholder img.loaded { opacity: 1; }

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

    <header class="text-center header-sticky py-3">
        <div class="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8">
            <div class="flex items-center justify-between h-auto md:h-14 mb-4">
                <div class="flex-1"></div>
                <h1 class="text-4xl md:text-5xl font-bold text-center whitespace-nowrap">图片画廊</h1>
                <div class="flex-1 flex items-center justify-end gap-1">
                    <button id="search-toggle-btn" title="搜索" class="p-2 rounded-full text-[var(--text-color)] hover:bg-gray-500/10"><svg class="w-6 h-6" xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor"><path stroke-linecap="round" stroke-linejoin="round" d="m21 21-5.197-5.197m0 0A7.5 7.5 0 1 0 5.196 5.196a7.5 7.5 0 0 0 10.607 10.607Z" /></svg></button>
                    <button id="theme-toggle" title="切换主题" class="p-2 rounded-full text-[var(--text-color)] hover:bg-gray-500/10"><svg id="theme-icon-sun" class="w-6 h-6" fill="none" viewBox="0 0 24 24" stroke="currentColor"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 3v1m0 16v1m9-9h-1M4 12H3m15.364 6.364l-.707-.707M6.343 6.343l-.707-.707m12.728 0l-.707.707M6.343 17.657l-.707.707M16 12a4 4 0 11-8 0 4 4 0 018 0z" /></svg><svg id="theme-icon-moon" class="w-6 h-6 hidden" fill="none" viewBox="0 0 24 24" stroke="currentColor"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M20.354 15.354A9 9 0 018.646 3.646 9.003 9.003 0 0012 21a9.003 9.003 0 008.354-5.646z" /></svg></button>
                </div>
            </div>
            <div id="filter-buttons" class="flex justify-center flex-wrap gap-2 px-4"><button class="filter-btn active" data-filter="all">全部</button><button class="filter-btn" data-filter="random">随机</button></div>
        </div>
    </header>
    
    <div class="border-b-2" style="border-color: var(--divider-color);"></div>

    <main class="max-w-7xl mx-auto w-full px-4 py-8 md:py-10">
        <div id="gallery-container" class="mx-auto"></div>
        <div id="loader" class="text-center py-8 hidden">正在加载更多...</div>
    </main>
    
    <footer class="text-center py-6 mt-auto border-t" style="border-color: var(--divider-color);"><p>© 2025 图片画廊</p></footer>

    <div id="search-overlay" class="fixed inset-0 z-50 flex items-start justify-center pt-24 md:pt-32 p-4"><div id="search-box" class="w-full max-w-lg relative rounded-lg"><input type="search" id="search-input" placeholder="输入关键词，按 Enter 搜索..." class="w-full py-4 pl-6 pr-16 text-lg rounded-lg border-0"><button id="search-exec-btn" class="absolute h-full right-0 top-0 text-gray-500 hover:text-green-600 px-5 transition-colors"><svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="2" stroke="currentColor" class="w-6 h-6"><path stroke-linecap="round" stroke-linejoin="round" d="m21 21-5.197-5.197m0 0A7.5 7.5 0 1 0 5.196 5.196a7.5 7.5 0 0 0 10.607 10.607Z" /></svg></button></div></div>
    <div class="lightbox"><span class="lb-counter"></span><button class="lightbox-btn lb-close">&times;</button><button class="lightbox-btn lb-prev">&lsaquo;</button><img class="lightbox-image" alt=""><button class="lightbox-btn lb-next">&rsaquo;</button><a href="#" id="lightbox-download-link" download class="lb-download">下载</a></div>
    <a class="back-to-top" title="返回顶部"><svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 19V5M5 12l7-7 7 7"/></svg></a>

    <script>
    document.addEventListener('DOMContentLoaded', function () {
        const body = document.body;
        const galleryContainer = document.getElementById('gallery-container');
        const loader = document.getElementById('loader');
        const filterButtonsContainer = document.getElementById('filter-buttons');
        const header = document.querySelector('.header-sticky');
        
        let masonry;
        let allLoadedImages = []; let currentFilter = 'all'; let currentSearch = ''; let currentPage = 1; let isLoading = false; let hasMoreImages = true; let lastFocusedElement;
        
        const searchToggleBtn = document.getElementById('search-toggle-btn');
        const themeToggleBtn = document.getElementById('theme-toggle');
        const searchOverlay = document.getElementById('search-overlay');
        const searchInput = document.getElementById('search-input');
        const searchExecBtn = document.getElementById('search-exec-btn');
        
        const openSearch = () => { searchOverlay.classList.add('active'); body.classList.add('overflow-hidden'); setTimeout(() => searchInput.focus(), 50); };
        const closeSearch = () => { searchOverlay.classList.remove('active'); body.classList.remove('overflow-hidden'); };
        searchToggleBtn.addEventListener('click', openSearch);
        searchOverlay.addEventListener('click', (e) => { if (e.target === searchOverlay) closeSearch(); });
        document.addEventListener('keydown', (e) => { if (e.key === 'Escape' && searchOverlay.classList.contains('active')) closeSearch(); });
        
        const performSearch = () => { const newSearchTerm = searchInput.value.trim(); if (newSearchTerm === currentSearch) { closeSearch(); return; } currentSearch = newSearchTerm; document.querySelectorAll('.filter-btn').forEach(btn => btn.classList.remove('active')); filterButtonsContainer.querySelector('[data-filter="all"]').classList.add('active'); currentFilter = 'all'; closeSearch(); resetGallery(); fetchAndRenderImages(); };
        searchInput.addEventListener('keydown', (e) => { if (e.key === 'Enter') performSearch(); });
        searchExecBtn.addEventListener('click', performSearch);
        
        const applyTheme = (theme) => { const isDark = theme === 'dark'; body.classList.toggle('dark', isDark); document.getElementById('theme-icon-sun').classList.toggle('hidden', isDark); document.getElementById('theme-icon-moon').classList.toggle('hidden', !isDark); };
        themeToggleBtn.addEventListener('click', () => { const newTheme = body.classList.contains('dark') ? 'light' : 'dark'; localStorage.setItem('theme', newTheme); applyTheme(newTheme); });
        applyTheme(localStorage.getItem('theme') || (window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light'));

        const fetchJSON = async (url) => { const response = await fetch(url); if (!response.ok) throw new Error(`HTTP error! status: ${response.status}`); return response.json(); };
        const resetGallery = () => { if (masonry) { masonry.remove(Array.from(galleryContainer.children)); masonry.layout(); } allLoadedImages = []; currentPage = 1; hasMoreImages = true; window.scrollTo(0, 0); loader.textContent = '正在加载更多...'; };
        const fetchAndRenderImages = async () => {
            if (isLoading || !hasMoreImages) return;
            isLoading = true;
            loader.classList.remove('hidden');
            try {
                const url = `/api/images?page=${currentPage}&limit=20&category=${currentFilter}&search=${encodeURIComponent(currentSearch)}`;
                const data = await fetchJSON(url);
                if (data.images && data.images.length > 0) {
                    const itemsFragment = renderItems(data.images);
                    const newItems = Array.from(itemsFragment.children);
                    galleryContainer.appendChild(itemsFragment);
                    masonry.appended(newItems);
                    imagesLoaded(galleryContainer).on('progress', () => masonry.layout());
                    allLoadedImages.push(...data.images);
                    currentPage++;
                    hasMoreImages = data.hasMore;
                } else { hasMoreImages = false; if (allLoadedImages.length === 0) loader.textContent = '没有找到符合条件的图片。'; }
            } catch (error) { console.error('获取图片数据失败:', error); loader.textContent = '加载失败，请刷新页面。'; } 
            finally { isLoading = false; if (!hasMoreImages) loader.classList.add('hidden'); }
        };

        const renderItems = (images) => {
            const fragment = document.createDocumentFragment();
            images.forEach(image => {
                const item = document.createElement('div');
                item.className = 'grid-item';
                item.dataset.id = image.id;
                
                if (image.width && image.height && (image.width / image.height > 1.3)) {
                    item.classList.add('grid-item--width2');
                }

                const link = document.createElement('a');
                link.href = "#"; link.setAttribute('role', 'button'); link.setAttribute('aria-label', image.description || image.originalFilename);

                const placeholder = document.createElement('div');
                placeholder.className = 'image-placeholder';

                const spinner = document.createElement('div');
                spinner.className = 'spinner';

                const img = document.createElement('img');
                img.src = `/image-proxy/${image.filename}?w=800`;
                img.alt = image.description || image.originalFilename;

                img.addEventListener('load', () => {
                    img.classList.add('loaded');
                    placeholder.classList.add('item-loaded');
                    if (masonry) masonry.layout();
                });
                img.addEventListener('error', () => {
                    item.style.display = 'none';
                    if (masonry) masonry.layout();
                });
                
                placeholder.appendChild(spinner);
                placeholder.appendChild(img);
                link.appendChild(placeholder);
                item.appendChild(link);
                fragment.appendChild(item);
            });
            return fragment;
        };
        
        const createFilterButtons = async () => { try { const categories = await fetchJSON('/api/public/categories'); filterButtonsContainer.querySelectorAll('.dynamic-filter').forEach(btn => btn.remove()); categories.forEach(category => { const button = document.createElement('button'); button.className = 'filter-btn dynamic-filter'; button.dataset.filter = category; button.textContent = category; filterButtonsContainer.appendChild(button); }); } catch (error) { console.error('无法加载分类按钮:', error); } };
        filterButtonsContainer.addEventListener('click', (e) => { const target = e.target.closest('.filter-btn'); if (!target || target.classList.contains('active')) return; currentFilter = target.dataset.filter; currentSearch = ''; searchInput.value = ''; document.querySelectorAll('.filter-btn').forEach(btn => btn.classList.remove('active')); target.classList.add('active'); resetGallery(); fetchAndRenderImages(); });

        const lightbox = document.querySelector('.lightbox'); const lightboxImage = lightbox.querySelector('.lightbox-image'); const lbCounter = lightbox.querySelector('.lb-counter'); const lbDownloadLink = document.getElementById('lightbox-download-link'); let currentImageIndexInFiltered = 0;
        galleryContainer.addEventListener('click', (e) => { e.preventDefault(); const item = e.target.closest('.grid-item'); if (item) { lastFocusedElement = document.activeElement; currentImageIndexInFiltered = allLoadedImages.findIndex(img => img.id === item.dataset.id); if (currentImageIndexInFiltered === -1) return; updateLightbox(); lightbox.classList.add('active'); document.body.classList.add('overflow-hidden'); } });
        const updateLightbox = () => { const currentItem = allLoadedImages[currentImageIndexInFiltered]; if (!currentItem) return; lightboxImage.src = `/image-proxy/${currentItem.filename}`; lightboxImage.alt = currentItem.description; lbCounter.textContent = `${currentImageIndexInFiltered + 1} / ${allLoadedImages.length}`; lbDownloadLink.href = currentItem.src; lbDownloadLink.download = currentItem.originalFilename; };
        const showPrevImage = () => { currentImageIndexInFiltered = (currentImageIndexInFiltered - 1 + allLoadedImages.length) % allLoadedImages.length; updateLightbox(); };
        const showNextImage = () => { currentImageIndexInFiltered = (currentImageIndexInFiltered + 1) % allLoadedImages.length; updateLightbox(); };
        const closeLightbox = () => { lightbox.classList.remove('active'); document.body.classList.remove('overflow-hidden'); if(lastFocusedElement) lastFocusedElement.focus(); };
        lightbox.addEventListener('click', (e) => { const target = e.target; if (target.matches('.lb-next')) showNextImage(); else if (target.matches('.lb-prev')) showPrevImage(); else if (target.matches('.lb-close') || target === lightbox) closeLightbox(); });
        document.addEventListener('keydown', (e) => { if (lightbox.classList.contains('active')) { if (e.key === 'ArrowLeft') showPrevImage(); else if (e.key === 'ArrowRight') showNextImage(); else if (e.key === 'Escape') closeLightbox(); } });
        
        const backToTopBtn = document.querySelector('.back-to-top');
        backToTopBtn.addEventListener('click', () => window.scrollTo({ top: 0, behavior: 'smooth' })); 
        
        let lastScrollY = window.scrollY; let ticking = false;
        function handleScroll() { const currentScrollY = window.scrollY; if (currentScrollY > 300) backToTopBtn.classList.add('visible'); else backToTopBtn.classList.remove('visible'); if (currentScrollY > lastScrollY && currentScrollY > header.offsetHeight) { header.classList.add('is-hidden'); } else { header.classList.remove('is-hidden'); } lastScrollY = currentScrollY <= 0 ? 0 : currentScrollY; if (window.innerHeight + window.scrollY >= document.body.offsetHeight - 500) { fetchAndRenderImages(); } }
        window.addEventListener('scroll', () => { if (!ticking) { window.requestAnimationFrame(() => { handleScroll(); ticking = false; }); ticking = true; } }); 
        
        async function init() { 
            masonry = new Masonry(galleryContainer, {
                itemSelector: '.grid-item',
                columnWidth: '.grid-item',
                percentPosition: true,
                gutter: 16,
                transitionDuration: '0.3s'
            });
            await createFilterButtons(); 
            await fetchAndRenderImages(); 
        }
        init();
    });
    </script>
</body>
</html>
EOF

    echo "--> 正在生成后台管理页 public/admin.html..."
cat << 'EOF' > public/admin.html
<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0"><title>后台管理 - 图片画廊</title>
    <script src="https://cdn.tailwindcss.com"></script>
    <style> 
        body { background-color: #f8fafc; } 
        .modal, .toast { display: none; } 
        .modal.active, .lightbox.active { display: flex; } 
        body.lightbox-open { overflow: hidden; } 
        .nav-item.active { background-color: #dcfce7; font-weight: bold; } 
        .toast { position: fixed; top: 1.5rem; right: 1.5rem; z-index: 9999; transform: translateX(120%); transition: transform 0.3s ease-in-out; } 
        .toast.show { transform: translateX(0); } 
        .file-preview-item.upload-success { background-color: #f0fdf4; } 
        .file-preview-item.upload-error { background-color: #fef2f2; } 
        .admin-image-card { transition: opacity 0.4s ease, transform 0.4s ease; }
        .admin-image-card.fading-out { opacity: 0; transform: scale(0.95); }
        
        .image-preview-container {
            height: 9rem;
            background-color: #f1f5f9;
            border-radius: 0.25rem;
            overflow: hidden;
            display: flex;
            align-items: center;
            justify-content: center;
        }
        .image-preview-container img {
            max-width: 100%;
            max-height: 100%;
            object-fit: contain;
        }
        .page-item {
            transition: all 0.2s ease-in-out;
        }
        .page-item.active {
            background-color: #15803d;
            color: white;
            border-color: #14532d;
            font-weight: 700;
            transform: scale(1.1);
        }
        .lightbox { position: fixed; top: 0; left: 0; width: 100%; height: 100%; background-color: rgba(0, 0, 0, 0.9); display: none; justify-content: center; align-items: center; z-index: 1000; opacity: 0; visibility: hidden; transition: opacity 0.3s ease; }
        .lightbox-image { max-width: 85%; max-height: 85%; display: block; object-fit: contain; }
        .lightbox-btn { position: absolute; top: 50%; transform: translateY(-50%); background-color: rgba(255,255,255,0.1); color: white; border: none; font-size: 2.5rem; cursor: pointer; padding: 0.5rem 1rem; border-radius: 0.5rem; transition: background-color 0.2s; }
        .lightbox-btn:hover { background-color: rgba(255,255,255,0.2); }
        .lb-prev { left: 1rem; } .lb-next { right: 1rem; } .lb-close { top: 1rem; right: 1rem; font-size: 2rem; }
        .lb-counter { position: absolute; top: 1.5rem; left: 50%; transform: translateX(-50%); color: white; font-size: 1rem; background-color: rgba(0,0,0,0.3); padding: 0.25rem 0.75rem; border-radius: 9999px; }
        .lb-download { position: absolute; bottom: 1rem; right: 1rem; background-color: #22c55e; color: white; border: none; padding: 0.5rem 1rem; border-radius: 0.5rem; cursor: pointer; transition: background-color 0.2s; font-size: 1rem; text-decoration: none; }
        .lb-download:hover { background-color: #16a34a; }
    </style>
</head>
<body class="antialiased text-slate-800">
    <header class="bg-white shadow-md p-4 flex justify-between items-center sticky top-0 z-20">
        <h1 class="text-2xl font-bold text-slate-900">内容管理系统</h1>
        <div class="flex items-center gap-2">
            <a href="/" target="_blank" title="查看前台" class="flex items-center gap-2 bg-white border border-gray-300 text-gray-700 font-semibold py-2 px-4 rounded-lg hover:bg-gray-50 transition-colors"><svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor" class="w-5 h-5"><path stroke-linecap="round" stroke-linejoin="round" d="M13.5 6H5.25A2.25 2.25 0 003 8.25v10.5A2.25 2.25 0 005.25 21h10.5A2.25 2.25 0 0018 18.75V10.5m-4.5 0V6.375c0-.621.504-1.125 1.125-1.125h1.125c.621 0 1.125.504 1.125 1.125V10.5m-4.5 0h4.5m-4.5 0a2.25 2.25 0 01-2.25-2.25V8.25c0-.621.504-1.125 1.125-1.125h1.125c.621 0 1.125.504 1.125 1.125v3.375M3 11.25h1.5m1.5 0h1.5m-1.5 0l1.5-1.5m-1.5 1.5l-1.5-1.5m9 6.75l1.5-1.5m-1.5 1.5l-1.5-1.5" /></svg><span class="hidden sm:inline">查看前台</span></a>
            <a href="/api/logout" title="退出登录" class="flex items-center gap-2 bg-red-600 hover:bg-red-700 text-white font-bold py-2 px-4 rounded-lg transition-colors"><svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor" class="w-5 h-5"><path stroke-linecap="round" stroke-linejoin="round" d="M15.75 9V5.25A2.25 2.25 0 0013.5 3h-6a2.25 2.25 0 00-2.25 2.25v13.5A2.25 2.25 0 007.5 21h6a2.25 2.25 0 002.25-2.25V15M12 9l-3 3m0 0l3 3m-3-3h12.75" /></svg><span class="hidden sm:inline">退出登录</span></a>
        </div>
    </header>
    <main class="container mx-auto p-4 md:p-6 grid grid-cols-1 xl:grid-cols-12 gap-8">
        <div class="xl:col-span-4 space-y-8">
            <section id="upload-section" class="bg-white p-6 rounded-lg shadow-md"><h2 class="text-xl font-semibold mb-4">上传新图片</h2><form id="upload-form" class="space-y-4"><div><label for="image-input" id="drop-zone" class="w-full flex flex-col items-center justify-center p-6 border-2 border-dashed border-gray-300 rounded-lg cursor-pointer hover:bg-gray-50 transition-colors"><svg class="w-10 h-10 mb-3 text-gray-400" aria-hidden="true" xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 20 16"><path stroke="currentColor" stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M13 13h3a3 3 0 0 0 0-6h-.025A5.56 5.56 0 0 0 16 6.5 5.5 5.5 0 0 0 5.207 5.021C5.137 5.017 5.071 5 5 5a4 4 0 0 0 0 8h2.167M10 15V6m0 0L8 8m2-2 2 2"/></svg><p class="text-sm text-gray-500"><span class="font-semibold">点击选择</span> 或拖拽多个文件到此处</p><input id="image-input" type="file" class="hidden" multiple accept="image/*"/></label></div><div class="space-y-2"><label for="unified-description" class="block text-sm font-medium">统一描述 (可选)</label><textarea id="unified-description" rows="2" class="w-full text-sm border rounded px-2 py-1" placeholder="在此处填写可应用到所有未填写描述的图片"></textarea></div><div id="file-preview-container" class="hidden space-y-2"><div id="upload-summary" class="text-sm font-medium text-slate-600"></div><div id="file-preview-list" class="h-48 border rounded p-2 space-y-3" style="overflow: auto; resize: vertical;"></div></div><div><label for="category-select" class="block text-sm font-medium mb-1">设置分类</label><div class="flex items-center space-x-2"><select name="category" id="category-select" required class="w-full border rounded px-3 py-2 focus:outline-none focus:ring-2 focus:ring-green-500"></select><button type="button" id="add-category-btn" class="flex-shrink-0 bg-green-500 hover:bg-green-600 text-white font-bold w-9 h-9 rounded-full flex items-center justify-center text-xl" title="添加新分类">+</button></div></div><button type="submit" id="upload-btn" class="w-full bg-green-600 hover:bg-green-700 text-white font-bold py-2 px-4 rounded-lg transition-colors disabled:bg-gray-400" disabled>上传文件</button></form></section>
            <section class="bg-white p-6 rounded-lg shadow-md"><h2 class="text-xl font-semibold mb-4">图库</h2><div id="navigation-list" class="space-y-1"><div id="nav-item-all" data-view="all" class="nav-item flex items-center gap-3 p-2 rounded cursor-pointer hover:bg-gray-100 active"><svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20" fill="currentColor" class="w-5 h-5 text-slate-500"><path fill-rule="evenodd" d="M1 5.25A2.25 2.25 0 013.25 3h13.5A2.25 2.25 0 0119 5.25v9.5A2.25 2.25 0 0116.75 17H3.25A2.25 2.25 0 011 14.75v-9.5zm1.5 5.81v3.69c0 .414.336.75.75.75h13.5a.75.75 0 00.75-.75v-3.69l-2.72-2.72a.75.75 0 00-1.06 0L11.5 10l-1.72-1.72a.75.75 0 00-1.06 0l-4 4zM12.5 7a1.5 1.5 0 11-3 0 1.5 1.5 0 013 0z" clip-rule="evenodd" /></svg><span class="category-name flex-grow">所有图片</span></div><div id="category-dynamic-list"></div><hr class="my-2"><div id="nav-item-recycle-bin" data-view="recycle_bin" class="nav-item flex items-center gap-3 p-2 rounded cursor-pointer hover:bg-gray-100"><svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20" fill="currentColor" class="w-5 h-5 text-slate-500"><path fill-rule="evenodd" d="M8.75 1A2.75 2.75 0 006 3.75V4.5h8V3.75A2.75 2.75 0 0011.25 1h-2.5zM10 4.5a.75.75 0 00-1.5 0v.75h1.5v-.75zM15.25 6H4.75a.75.75 0 000 1.5h10.5a.75.75 0 000-1.5zM4.75 9.75a.75.75 0 01.75-.75h8.5a.75.75 0 010 1.5h-8.5a.75.75 0 01-.75-.75zM5.5 12a.75.75 0 00-1.5 0v2.75A2.75 2.75 0 006.75 17h6.5A2.75 2.75 0 0016 14.75V12a.75.75 0 00-1.5 0v2.75a1.25 1.25 0 01-1.25 1.25h-6.5a1.25 1.25 0 01-1.25-1.25V12z" clip-rule="evenodd" /></svg><span class="category-name flex-grow">回收站</span></div></div></section>
            <section class="bg-white p-6 rounded-lg shadow-md"><h2 class="text-xl font-semibold mb-4">安全</h2><div id="security-section"></div></section>
        </div>
        <section class="bg-white p-6 rounded-lg shadow-md xl:col-span-8 flex flex-col"><div class="flex flex-col md:flex-row justify-between items-center mb-4 gap-4"><h2 id="image-list-header" class="text-xl font-semibold text-slate-900 flex-grow"></h2><div class="w-full md:w-64"><input type="search" id="search-input" placeholder="在当前视图下搜索..." class="w-full border rounded-full px-4 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-green-500"></div></div><div id="image-list" class="grid grid-cols-1 sm:grid-cols-2 md:grid-cols-2 lg:grid-cols-3 2xl:grid-cols-4 gap-4 flex-grow content-start"></div><div id="image-loader" class="text-center py-8 text-slate-500 hidden">正在加载...</div><div id="pagination-container" class="mt-6 flex justify-center"></div></section>
    </main>
    <div id="generic-modal" class="modal fixed inset-0 bg-black bg-opacity-50 items-center justify-center z-30 p-4"><div class="bg-white rounded-lg shadow-xl p-6 w-full max-w-sm"><h3 id="modal-title" class="text-lg font-bold mb-4"></h3><div id="modal-body" class="mb-4 text-slate-600"></div><div id="modal-footer" class="flex justify-end space-x-2"></div></div></div>
    <div id="edit-image-modal" class="modal fixed inset-0 bg-black bg-opacity-50 items-center justify-center z-30 p-4"><div class="bg-white rounded-lg shadow-xl p-6 w-full max-w-md"><h3 class="text-lg font-bold mb-4">编辑图片信息</h3><form id="edit-image-form"><input type="hidden" id="edit-id"><div class="mb-4"><label for="edit-originalFilename" class="block text-sm font-medium mb-1">原始文件名</label><input type="text" id="edit-originalFilename" class="w-full border rounded px-3 py-2"></div><div class="mb-4"><label for="edit-category-select" class="block text-sm font-medium mb-1">分类</label><select id="edit-category-select" class="w-full border rounded px-3 py-2"></select></div><div class="mb-4"><label for="edit-description" class="block text-sm font-medium mb-1">描述</label><textarea id="edit-description" rows="3" class="w-full border rounded px-3 py-2"></textarea></div><div class="flex justify-end space-x-2 mt-6"><button type="button" class="modal-cancel-btn bg-gray-300 hover:bg-gray-400 text-black py-2 px-4 rounded">取消</button><button type="submit" class="bg-blue-600 hover:bg-blue-700 text-white py-2 px-4 rounded">保存更改</button></div></form></div></div>
    <div id="tfa-modal" class="modal fixed inset-0 bg-black bg-opacity-50 items-center justify-center z-30 p-4"><div class="bg-white rounded-lg shadow-xl p-6 w-full max-w-md"><h3 class="text-lg font-bold mb-4">设置两步验证 (2FA)</h3><div id="tfa-setup-content"></div><div class="flex justify-end space-x-2 mt-6"><button type="button" class="modal-cancel-btn bg-gray-300 hover:bg-gray-400 text-black py-2 px-4 rounded">关闭</button></div></div></div>
    <div id="lightbox" class="lightbox"><span id="lb-counter" class="lb-counter"></span><button class="lightbox-btn lb-close">&times;</button><button class="lightbox-btn lb-prev">&lsaquo;</button><img class="lightbox-image" alt=""><button class="lightbox-btn lb-next">&rsaquo;</button><a href="#" id="lb-download" download class="lb-download">下载</a></div>
    <div id="toast" class="toast max-w-xs bg-gray-800 text-white text-sm rounded-lg shadow-lg p-3" role="alert"><div class="flex items-center"><div id="toast-icon" class="mr-2"></div><span id="toast-message"></span></div></div>
    <script>
    document.addEventListener('DOMContentLoaded', function() {
        const UNCATEGORIZED = '未分类';
        const DOMElements = {
            uploadForm: document.getElementById('upload-form'), uploadBtn: document.getElementById('upload-btn'), imageInput: document.getElementById('image-input'),
            dropZone: document.getElementById('drop-zone'), unifiedDescription: document.getElementById('unified-description'), filePreviewContainer: document.getElementById('file-preview-container'),
            filePreviewList: document.getElementById('file-preview-list'), uploadSummary: document.getElementById('upload-summary'), categorySelect: document.getElementById('category-select'),
            editCategorySelect: document.getElementById('edit-category-select'), addCategoryBtn: document.getElementById('add-category-btn'), navigationList: document.getElementById('navigation-list'),
            categoryDynamicList: document.getElementById('category-dynamic-list'), imageList: document.getElementById('image-list'), imageListHeader: document.getElementById('image-list-header'),
            imageLoader: document.getElementById('image-loader'), searchInput: document.getElementById('search-input'), genericModal: document.getElementById('generic-modal'),
            editImageModal: document.getElementById('edit-image-modal'), editImageForm: document.getElementById('edit-image-form'), securitySection: document.getElementById('security-section'), tfaModal: document.getElementById('tfa-modal'),
            paginationContainer: document.getElementById('pagination-container'),
            lightbox: document.getElementById('lightbox'),
            lightboxImage: document.querySelector('#lightbox .lightbox-image'),
            lightboxCounter: document.getElementById('lb-counter'),
            lightboxDownloadLink: document.getElementById('lb-download')
        };
        let filesToUpload = []; let adminLoadedImages = []; let currentLightboxIndex = 0; let currentSearchTerm = ''; let debounceTimer; let currentAdminPage = 1;
        
        const apiRequest = async (url, options = {}) => {
            try {
                const response = await fetch(url, options);
                if (response.status === 401) { 
                    showToast('登录状态已过期', 'error'); 
                    setTimeout(() => window.location.href = '/login.html', 2000); 
                    throw new Error('Unauthorized'); 
                }
                if (!response.ok) {
                    let errorMsg = `HTTP Error: ${response.status} ${response.statusText}`;
                    try {
                        const errorJson = await response.json();
                        errorMsg = errorJson.message || errorMsg;
                    } catch (e) { /* Ignore if body is not JSON */ }
                    throw new Error(errorMsg);
                }
                return response;
            } catch (error) {
                if (error instanceof TypeError) {
                    throw new Error('网络错误，请检查您的连接。');
                }
                throw error;
            }
        };

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
            if (pendingFiles.length === 0) {
                showToast("没有需要上传的新文件。", "error");
                DOMElements.uploadBtn.disabled = filesToUpload.length === 0;
                return;
            }
            try {
                const filenamesToCheck = pendingFiles.map(item => item.file.name);
                const response = await apiRequest('/api/admin/check-filenames', { method: 'POST', headers: {'Content-Type': 'application/json'}, body: JSON.stringify({filenames: filenamesToCheck}) });
                const { duplicates } = await response.json();

                for (const item of pendingFiles) {
                    if (duplicates.includes(item.file.name)) {
                        const userConfirmed = await showConfirmationModal('文件已存在', `文件 "<strong>${item.file.name}</strong>" 已存在。是否仍然继续上传？<br>(新文件将被自动重命名)`, '继续上传', '取消此文件');
                        if (userConfirmed) { item.shouldRename = true; } 
                        else { item.status = 'cancelled'; const previewItem = DOMElements.filePreviewList.querySelector(`[data-file-index="${filesToUpload.indexOf(item)}"]`); if(previewItem) previewItem.querySelector('.upload-status').textContent = '已取消'; }
                    }
                }
            } catch (error) {
                showToast(`检查文件名出错: ${error.message}`, 'error');
                DOMElements.uploadBtn.disabled = false;
                return;
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
                    const formData = new FormData();
                    formData.append('image', item.file);
                    formData.append('category', DOMElements.categorySelect.value);
                    formData.append('description', item.description);
                    formData.append('rename', item.shouldRename);
                    await apiRequest('/api/admin/upload', { method: 'POST', body: formData });
                    item.status = 'success';
                    previewItem.classList.add('upload-success');
                    statusEl.textContent = '✅ 上传成功';
                } catch (err) {
                    if (err.message !== 'Unauthorized') {
                        item.status = 'error';
                        statusEl.textContent = `❌ ${err.message}`;
                        previewItem.classList.add('upload-error');
                    }
                } finally {
                    processedCount++;
                    updateButtonText();
                }
            }
            showToast(`所有任务处理完成。`);
            DOMElements.uploadBtn.textContent = '上传文件';
            filesToUpload = [];
            DOMElements.imageInput.value = '';
            DOMElements.unifiedDescription.value = '';
            setTimeout(() => { DOMElements.filePreviewContainer.classList.add('hidden'); DOMElements.uploadBtn.disabled = true; }, 3000);
            await refreshAllData();
        };
        DOMElements.uploadForm.addEventListener('submit', processUploadQueue);

        async function refreshAllData() { await refreshNavigation(); const activeNav = document.querySelector('.nav-item.active'); if (activeNav) { activeNav.click(); } else { document.getElementById('nav-item-all').click(); } }
        async function populateCategorySelects(selectedCategory = null) { try { const response = await apiRequest('/api/categories'); const categories = await response.json(); [DOMElements.categorySelect, DOMElements.editCategorySelect].forEach(select => { const currentVal = select.value; select.innerHTML = ''; categories.forEach(cat => select.add(new Option(cat, cat))); select.value = categories.includes(currentVal) ? currentVal : selectedCategory || categories[0] || ''; }); } catch (error) { if (error.message !== 'Unauthorized') console.error('加载分类失败:', error.message); } }
        async function refreshNavigation() { try { const response = await apiRequest('/api/categories'); const categories = await response.json(); DOMElements.categoryDynamicList.innerHTML = ''; categories.forEach(cat => { const isUncategorized = cat === UNCATEGORIZED; const item = document.createElement('div'); item.className = 'nav-item flex items-center justify-between p-2 rounded cursor-pointer hover:bg-gray-100'; item.dataset.view = 'category'; item.dataset.categoryName = cat; item.innerHTML = `<span class="category-name flex-grow">${cat}</span>` + (isUncategorized ? '' : `<div class="space-x-2 flex-shrink-0 opacity-0 group-hover:opacity-100 transition-opacity"><button data-name="${cat}" class="rename-cat-btn text-blue-500 hover:text-blue-700 text-sm">重命名</button><button data-name="${cat}" class="delete-cat-btn text-red-500 hover:red-700 text-sm">删除</button></div>`); item.addEventListener('mouseenter', () => item.classList.add('group')); item.addEventListener('mouseleave', () => item.classList.remove('group')); DOMElements.categoryDynamicList.appendChild(item); }); await populateCategorySelects(); } catch (error) { if (error.message !== 'Unauthorized') console.error('加载导航列表失败:', error.message); } }
        
        async function loadImages(category, name) { DOMElements.imageLoader.classList.remove('hidden'); DOMElements.imageList.innerHTML = ''; DOMElements.paginationContainer.innerHTML = ''; try { const url = `/api/images?category=${category}&search=${encodeURIComponent(currentSearchTerm)}&page=${currentAdminPage}&limit=12`; const response = await apiRequest(url); const data = await response.json(); adminLoadedImages = data.images; DOMElements.imageListHeader.innerHTML = `${name} <span class="text-base text-gray-500 font-normal">(共 ${data.totalImages} 张)</span>`; if (adminLoadedImages.length === 0) { DOMElements.imageList.innerHTML = '<p class="text-slate-500 col-span-full text-center py-10">没有找到图片。</p>'; } else { adminLoadedImages.forEach(renderImageCard); } renderPaginationControls(data.page, data.totalPages); } catch (error) { if(error.message !== 'Unauthorized') DOMElements.imageList.innerHTML = `<p class="text-red-500 col-span-full text-center py-10">加载图片失败: ${error.message}</p>`; } finally { DOMElements.imageLoader.classList.add('hidden'); } }
        async function loadRecycleBin() { DOMElements.imageLoader.classList.remove('hidden'); DOMElements.imageList.innerHTML = ''; DOMElements.paginationContainer.innerHTML = ''; try { const url = `/api/admin/recycle-bin?search=${encodeURIComponent(currentSearchTerm)}&page=${currentAdminPage}&limit=12`; const response = await apiRequest(url); const data = await response.json(); adminLoadedImages = data.images; DOMElements.imageListHeader.innerHTML = `回收站`; if (adminLoadedImages.length === 0) { DOMElements.imageList.innerHTML = '<p class="text-slate-500 col-span-full text-center py-10">回收站是空的。</p>'; } else { adminLoadedImages.forEach(renderPurgeableImageCard); } renderPaginationControls(data.page, data.totalPages); } catch (error) { if (error.message !== 'Unauthorized') DOMElements.imageList.innerHTML = `<p class="text-red-500 col-span-full text-center py-10">加载回收站失败: ${error.message}</p>`; } finally { DOMElements.imageLoader.classList.add('hidden'); } }

        function createButton(options) {
            const btn = document.createElement(options.tag || 'button');
            btn.title = options.title;
            if (options.classes) btn.className = options.classes;
            if (options.html) btn.innerHTML = options.html;
            if (options.data) {
                for(const key in options.data) {
                    btn.dataset[key] = options.data[key];
                }
            }
            if (options.href) btn.href = options.href;
            if (options.download) btn.download = options.download;
            if (options.onClick) {
                btn.addEventListener('click', (e) => {
                    if (btn.tagName === 'A' && !btn.hasAttribute('download')) {
                        e.preventDefault();
                    }
                    options.onClick(e);
                });
            }
            return btn;
        }

        function renderImageCard(image) {
            const card = document.createElement('div');
            card.className = 'admin-image-card border rounded-lg shadow-sm bg-white overflow-hidden flex flex-col';

            const previewAction = () => {
                currentLightboxIndex = adminLoadedImages.findIndex(img => img.id === image.id);
                if (currentLightboxIndex === -1) return;
                updateLightbox();
                DOMElements.lightbox.classList.add('active');
                document.body.classList.add('lightbox-open');
            };

            const previewLink = createButton({ tag: 'a', classes: 'image-preview-container', data: { id: image.id }, onClick: previewAction });
            const img = document.createElement('img');
            img.src = `/image-proxy/${image.filename}?w=400`;
            img.alt = image.description;
            previewLink.appendChild(img);
            
            const infoDiv = document.createElement('div');
            infoDiv.className = 'p-3 flex-grow flex flex-col';
            infoDiv.innerHTML = `<p class="font-bold text-sm truncate" title="${image.originalFilename}">${image.originalFilename}</p><p class="text-xs text-slate-500 -mt-1 mb-2">${formatBytes(image.size)}</p><p class="text-xs text-slate-500 mb-2">${image.category}</p><p class="text-xs text-slate-600 flex-grow mb-3 break-words">${image.description || '无描述'}</p>`;
            
            const footerDiv = document.createElement('div');
            footerDiv.className = 'bg-slate-50 p-2 flex justify-end items-center gap-1';
            
            const previewBtn = createButton({ title: '预览', classes: 'p-2 rounded-full text-slate-600 hover:bg-slate-200 hover:text-slate-800 transition-colors', html: '<svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor" class="w-5 h-5"><path stroke-linecap="round" stroke-linejoin="round" d="M2.036 12.322a1.012 1.012 0 010-.639C3.423 7.51 7.36 4.5 12 4.5c4.638 0 8.573 3.007 9.963 7.178.07.207.07.431 0 .639C20.577 16.49 16.64 19.5 12 19.5c-4.638 0-8.573-3.007-9.963-7.178z" /><path stroke-linecap="round" stroke-linejoin="round" d="M15 12a3 3 0 11-6 0 3 3 0 016 0z" /></svg>', onClick: previewAction });
            const downloadBtn = createButton({ tag: 'a', title: '下载', classes: 'p-2 rounded-full text-slate-600 hover:bg-slate-200 hover:text-slate-800 transition-colors', href: image.src, download: image.originalFilename, html: '<svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor" class="w-5 h-5"><path stroke-linecap="round" stroke-linejoin="round" d="M3 16.5v2.25A2.25 2.25 0 005.25 21h13.5A2.25 2.25 0 0021 18.75V16.5M16.5 12L12 16.5m0 0L7.5 12m4.5 4.5V3" /></svg>'});
            const editBtn = createButton({ title: '编辑', classes: 'p-2 rounded-full text-slate-600 hover:bg-slate-200 hover:text-slate-800 transition-colors', html: '<svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor" class="w-5 h-5"><path stroke-linecap="round" stroke-linejoin="round" d="M16.862 4.487l1.687-1.688a1.875 1.875 0 112.652 2.652L6.832 19.82a4.5 4.5 0 01-1.897 1.13l-2.685.8.8-2.685a4.5 4.5 0 011.13-1.897L16.863 4.487zm0 0L19.5 7.125" /></svg>', onClick: async () => { await populateCategorySelects(image.category); DOMElements.editImageModal.querySelector('#edit-id').value = image.id; DOMElements.editImageModal.querySelector('#edit-originalFilename').value = image.originalFilename; DOMElements.editImageModal.querySelector('#edit-description').value = image.description; DOMElements.editImageModal.classList.add('active'); }});
            const deleteBtn = createButton({ title: '移至回收站', classes: 'p-2 rounded-full text-red-500 hover:bg-red-100 hover:text-red-700 transition-colors', html: '<svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor" class="w-5 h-5"><path stroke-linecap="round" stroke-linejoin="round" d="M14.74 9l-.346 9m-4.788 0L9.26 9m9.968-3.21c.342.052.682.107 1.022.166m-1.022-.165L18.16 19.673a2.25 2.25 0 01-2.244 2.077H8.084a2.25 2.25 0 01-2.244-2.077L4.772 5.79m14.456 0a48.108 48.108 0 00-3.478-.397m-12 .562c.34-.059.68-.114 1.022-.165m0 0a48.11 48.11 0 013.478-.397m7.5 0v-.916c0-1.18-.91-2.134-2.036-2.134H8.718c-1.126 0-2.037.955-2.037 2.134v.916m7.5 0a48.667 48.667 0 00-7.5 0" /></svg>', onClick: async () => { const confirmed = await showConfirmationModal('移至回收站', `<p>确定要将这张图片移至回收站吗？</p>`, '确认移动'); if(confirmed) { try { await apiRequest(`/api/admin/images/${image.id}`, { method: 'DELETE' }); showToast('图片已移至回收站'); card.classList.add('fading-out'); setTimeout(() => card.remove(), 400); adminLoadedImages = adminLoadedImages.filter(img => img.id !== image.id); } catch (error) { showToast(error.message, 'error'); } } }});

            footerDiv.append(previewBtn, downloadBtn, editBtn, deleteBtn);
            card.append(previewLink, infoDiv, footerDiv);
            DOMElements.imageList.appendChild(card);
        }

        function renderPurgeableImageCard(image) {
            const card = document.createElement('div');
            card.className = 'admin-image-card border rounded-lg shadow-sm bg-white overflow-hidden flex flex-col';

            const previewAction = () => {
                currentLightboxIndex = adminLoadedImages.findIndex(img => img.id === image.id);
                if (currentLightboxIndex === -1) return;
                updateLightbox();
                DOMElements.lightbox.classList.add('active');
                document.body.classList.add('lightbox-open');
            };

            const previewLink = createButton({ tag: 'a', classes: 'image-preview-container', data: { id: image.id }, onClick: previewAction });
            const img = document.createElement('img');
            img.src = `/image-proxy/${image.filename}?w=400`;
            img.alt = image.description || image.originalFilename;
            previewLink.appendChild(img);

            const infoDiv = document.createElement('div');
            infoDiv.className = 'p-3 flex-grow flex flex-col space-y-2';
            infoDiv.innerHTML = `<p class="font-bold text-sm truncate" title="${image.originalFilename}">${image.originalFilename}</p><div class="text-xs text-slate-500 space-y-1"><p><strong>大小:</strong> ${formatBytes(image.size)}</p><p><strong>分类:</strong> ${image.category}</p></div><p class="text-xs text-slate-600 flex-grow break-words">${image.description || '无描述'}</p><p class="text-xs text-red-500 mt-2"><strong>删除于:</strong> ${new Date(image.deletedAt).toLocaleString()}</p>`;
            
            const footerDiv = document.createElement('div');
            footerDiv.className = 'bg-slate-50 p-2 flex justify-end items-center gap-1';

            const previewBtn = createButton({ title: '预览', classes: 'p-2 rounded-full text-slate-600 hover:bg-slate-200 hover:text-slate-800 transition-colors', html: '<svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor" class="w-5 h-5"><path stroke-linecap="round" stroke-linejoin="round" d="M2.036 12.322a1.012 1.012 0 010-.639C3.423 7.51 7.36 4.5 12 4.5c4.638 0 8.573 3.007 9.963 7.178.07.207.07.431 0 .639C20.577 16.49 16.64 19.5 12 19.5c-4.638 0-8.573-3.007-9.963-7.178z" /><path stroke-linecap="round" stroke-linejoin="round" d="M15 12a3 3 0 11-6 0 3 3 0 016 0z" /></svg>', onClick: previewAction });
            const restoreBtn = createButton({ title: '恢复', classes: 'p-2 rounded-full text-green-600 hover:bg-green-100 transition-colors', html: '<svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor" class="w-5 h-5"><path stroke-linecap="round" stroke-linejoin="round" d="M9 15L3 9m0 0l6-6M3 9h12a6 6 0 010 12h-3" /></svg>', onClick: async () => { try { await apiRequest(`/api/admin/recycle-bin/${image.id}/restore`, { method: 'POST' }); showToast('图片已恢复'); card.classList.add('fading-out'); setTimeout(() => card.remove(), 400); adminLoadedImages = adminLoadedImages.filter(img => img.id !== image.id); } catch (error) { showToast(error.message, 'error'); } } });
            const purgeBtn = createButton({ title: '彻底删除', classes: 'p-2 rounded-full text-red-500 hover:bg-red-100 hover:text-red-700 transition-colors', html: '<svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor" class="w-5 h-5"><path stroke-linecap="round" stroke-linejoin="round" d="M14.74 9l-.346 9m-4.788 0L9.26 9m9.968-3.21c.342.052.682.107 1.022.166m-1.022-.165L18.16 19.673a2.25 2.25 0 01-2.244 2.077H8.084a2.25 2.25 0 01-2.244-2.077L4.772 5.79m14.456 0a48.108 48.108 0 00-3.478-.397m-12 .562c.34-.059.68-.114 1.022-.165m0 0a48.11 48.11 0 013.478-.397m7.5 0v-.916c0-1.18-.91-2.134-2.036-2.134H8.718c-1.126 0-2.037.955-2.037 2.134v.916m7.5 0a48.667 48.667 0 00-7.5 0" /></svg>', onClick: async () => { const confirmed = await showConfirmationModal('彻底删除', `<p>确定要永久删除这张图片吗？<br><strong>此操作无法撤销。</strong></p>`, '确认删除'); if (confirmed) { try { await apiRequest(`/api/admin/recycle-bin/${image.id}/purge`, { method: 'DELETE' }); showToast('图片已彻底删除'); card.classList.add('fading-out'); setTimeout(() => card.remove(), 400); adminLoadedImages = adminLoadedImages.filter(img => img.id !== image.id); } catch (error) { showToast(error.message, 'error'); } } } });

            footerDiv.append(previewBtn, restoreBtn, purgeBtn);
            card.append(previewLink, infoDiv, footerDiv);
            DOMElements.imageList.appendChild(card);
        }
        
        const changePage = (page) => {
            currentAdminPage = page;
            const activeNav = document.querySelector('.nav-item.active');
            if (!activeNav) return;
            const view = activeNav.dataset.view;
            const categoryName = activeNav.dataset.categoryName;
            const headerText = activeNav.querySelector('.category-name')?.textContent || '所有图片';
            if (view === 'recycle_bin') {
                loadRecycleBin();
            } else {
                loadImages(categoryName || 'all', headerText);
            }
        };
        function renderPaginationControls(currentPage, totalPages) {
            if (totalPages <= 1) { DOMElements.paginationContainer.innerHTML = ''; return; }
            let html = '<div class="flex items-center space-x-1">';
            const createButton = (text, page, disabled = false, active = false) => `<button data-page="${page}" class="page-item px-3 py-1 text-sm font-medium border border-gray-300 rounded-md hover:bg-gray-100 ${disabled ? 'disabled' : ''} ${active ? 'active' : ''}">${text}</button>`;
            html += createButton('上一页', currentPage - 1, currentPage === 1);
            
            let pages = [];
            if (totalPages <= 7) { for (let i = 1; i <= totalPages; i++) pages.push(i); }
            else {
                pages.push(1);
                if (currentPage > 3) pages.push('...');
                let start = Math.max(2, currentPage - 1); let end = Math.min(totalPages - 1, currentPage + 1);
                for (let i = start; i <= end; i++) pages.push(i);
                if (currentPage < totalPages - 2) pages.push('...');
                pages.push(totalPages);
            }
            pages.forEach(p => { if (p === '...') html += '<span class="px-3 py-1 text-sm">...</span>'; else html += createButton(p, p, false, p === currentPage); });

            html += createButton('下一页', currentPage + 1, currentPage === totalPages);
            html += '</div>';
            DOMElements.paginationContainer.innerHTML = html;
        }
        DOMElements.paginationContainer.addEventListener('click', e => { const target = e.target.closest('.page-item'); if(target && !target.classList.contains('disabled') && !target.classList.contains('active')) { changePage(parseInt(target.dataset.page)); } });

        DOMElements.navigationList.addEventListener('click', async (e) => {
            e.preventDefault();
            const navItem = e.target.closest('.nav-item');
            if (!navItem) return;
            if (e.target.matches('.rename-cat-btn, .delete-cat-btn')) { e.stopPropagation(); const catName = e.target.dataset.name; if (e.target.classList.contains('rename-cat-btn')) { showGenericModal(`重命名分类 "${catName}"`, '<form id="modal-form"><input type="text" id="modal-input" required class="w-full border rounded px-3 py-2"></form>', '<button type="button" class="modal-cancel-btn bg-gray-300 hover:bg-gray-400 text-black py-2 px-4 rounded">取消</button><button type="submit" form="modal-form" class="bg-blue-600 hover:bg-blue-700 text-white py-2 px-4 rounded">保存</button>'); const input = document.getElementById('modal-input'); input.value = catName; document.getElementById('modal-form').onsubmit = async (ev) => { ev.preventDefault(); const newName = input.value.trim(); if (!newName || newName === catName) { hideModal(DOMElements.genericModal); return; } try { await apiRequest('/api/admin/categories', { method: 'PUT', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ oldName: catName, newName }) }); hideModal(DOMElements.genericModal); showToast('重命名成功'); await refreshAllData(); } catch (error) { showToast(`重命名失败: ${error.message}`, 'error'); } }; } else if (e.target.classList.contains('delete-cat-btn')) { const confirmed = await showConfirmationModal('确认删除', `<p>确定要删除分类 "<strong>${catName}</strong>" 吗？<br>此分类下的图片将归入 "未分类"。</p>`, '确认删除'); if(confirmed) { try { await apiRequest('/api/admin/categories', { method: 'DELETE', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ name: catName }) }); showToast('删除成功'); await refreshAllData(); } catch (error) { showToast(`删除失败: ${error.message}`, 'error'); } } } return; }
            document.querySelectorAll('.nav-item').forEach(el => el.classList.remove('active'));
            navItem.classList.add('active');
            DOMElements.searchInput.value = ''; currentSearchTerm = ''; currentAdminPage = 1;
            const view = navItem.dataset.view;
            const categoryName = navItem.dataset.categoryName;
            const headerText = navItem.querySelector('.category-name')?.textContent || '所有图片';
            if (view === 'all') { await loadImages('all', headerText); }
            else if (view === 'recycle_bin') { await loadRecycleBin(); }
            else if (view === 'category') { await loadImages(categoryName, headerText); }
        });
        
        DOMElements.editImageForm.addEventListener('submit', async (e) => { e.preventDefault(); const id = document.getElementById('edit-id').value; const body = JSON.stringify({ originalFilename: document.getElementById('edit-originalFilename').value, category: DOMElements.editCategorySelect.value, description: document.getElementById('edit-description').value }); try { await apiRequest(`/api/admin/images/${id}`, { method: 'PUT', headers: { 'Content-Type': 'application/json' }, body }); hideModal(DOMElements.editImageModal); showToast('更新成功'); const activeNav = document.querySelector('.nav-item.active'); if (activeNav) { activeNav.click(); } } catch (error) { showToast(`更新失败: ${error.message}`, 'error'); } });
        
        async function renderSecuritySection() { try { const response = await apiRequest('/api/admin/2fa/status'); const { enabled } = await response.json(); let content; if (enabled) { content = `<p class="text-sm text-slate-600 mb-3">两步验证 (2FA) 当前已<span class="font-bold text-green-600">启用</span>。</p><button id="disable-tfa-btn" class="w-full bg-red-600 hover:bg-red-700 text-white font-bold py-2 px-4 rounded-lg">禁用 2FA</button>`; } else { content = `<p class="text-sm text-slate-600 mb-3">通过启用两步验证，为您的账户增加一层额外的安全保障。</p><button id="enable-tfa-btn" class="w-full bg-blue-600 hover:bg-blue-700 text-white font-bold py-2 px-4 rounded-lg">启用 2FA</button>`; } DOMElements.securitySection.innerHTML = content; } catch (error) { DOMElements.securitySection.innerHTML = `<p class="text-red-500">无法加载安全状态: ${error.message}</p>`; } }
        DOMElements.securitySection.addEventListener('click', async e => { if (e.target.id === 'enable-tfa-btn') { try { const response = await apiRequest('/api/admin/2fa/generate', {method: 'POST'}); const data = await response.json(); DOMElements.tfaModal.querySelector('#tfa-setup-content').innerHTML = `<p class="text-sm mb-4">1. 使用您的 Authenticator 应用 (如 Google Authenticator, Authy) 扫描下方的二维码。</p><img src="${data.qrCode}" alt="2FA QR Code" class="mx-auto border p-2 bg-white"><p class="text-sm mt-4 mb-2">或者手动输入密钥:</p><p class="font-mono bg-gray-100 p-2 rounded text-center text-sm break-all">${data.secret}</p><p class="text-sm mt-6 mb-2">2. 在下方输入应用生成的6位验证码以完成设置：</p><form id="tfa-verify-form" class="flex gap-2"><input type="text" id="tfa-token-input" required maxlength="6" class="w-full border rounded px-3 py-2" placeholder="6位数字码"><button type="submit" class="bg-green-600 hover:bg-green-700 text-white py-2 px-4 rounded">验证并启用</button></form><p id="tfa-error" class="text-red-500 text-sm mt-2 hidden"></p>`; DOMElements.tfaModal.classList.add('active'); document.getElementById('tfa-verify-form').addEventListener('submit', async ev => { ev.preventDefault(); const token = document.getElementById('tfa-token-input').value; try { const response = await apiRequest('/api/admin/2fa/enable', {method: 'POST', headers: {'Content-Type': 'application/json'}, body: JSON.stringify({ secret: data.secret, token })}); const result = await response.json(); showToast(result.message); hideModal(DOMElements.tfaModal); await renderSecuritySection(); } catch (err) { document.getElementById('tfa-error').textContent = err.message; document.getElementById('tfa-error').classList.remove('hidden'); } }); } catch (error) { showToast(error.message, 'error'); } } else if (e.target.id === 'disable-tfa-btn') { const confirmed = await showConfirmationModal('禁用 2FA', `<p>确定要禁用两步验证吗？您的账户安全性将会降低。</p>`, '确认禁用'); if (confirmed) { try { await apiRequest('/api/admin/2fa/disable', {method: 'POST'}); showToast('2FA已禁用'); await renderSecuritySection(); } catch(err) { showToast(err.message, 'error'); } } } });
        
        function updateLightbox() {
            const item = adminLoadedImages[currentLightboxIndex];
            if (!item) return;
            DOMElements.lightboxImage.src = `/image-proxy/${item.filename}`;
            DOMElements.lightboxImage.alt = item.description;
            DOMElements.lightboxCounter.textContent = `${currentLightboxIndex + 1} / ${adminLoadedImages.length}`;
            DOMElements.lightboxDownloadLink.href = item.src;
            DOMElements.lightboxDownloadLink.download = item.originalFilename;
        }
        function showNextImage() { currentLightboxIndex = (currentLightboxIndex + 1) % adminLoadedImages.length; updateLightbox(); }
        function showPrevImage() { currentLightboxIndex = (currentLightboxIndex - 1 + adminLoadedImages.length) % adminLoadedImages.length; updateLightbox(); }
        function closeLightbox() { DOMElements.lightbox.classList.remove('active'); document.body.classList.remove('lightbox-open'); }
        DOMElements.lightbox.addEventListener('click', e => { if (e.target.matches('.lb-next')) showNextImage(); else if (e.target.matches('.lb-prev')) showPrevImage(); else if (e.target.matches('.lb-close') || e.target === DOMElements.lightbox) closeLightbox(); });
        document.addEventListener('keydown', e => { if (DOMElements.lightbox.classList.contains('active')) { if (e.key === 'ArrowRight') showNextImage(); if (e.key === 'ArrowLeft') showPrevImage(); if (e.key === 'Escape') closeLightbox(); } });
        
        [DOMElements.genericModal, DOMElements.editImageModal, DOMElements.tfaModal].forEach(modal => { const cancelBtn = modal.querySelector('.modal-cancel-btn'); if(cancelBtn) { cancelBtn.addEventListener('click', () => hideModal(modal)); } modal.addEventListener('click', (e) => { if (e.target === modal) hideModal(modal); }); });
        
        async function init() { await Promise.all([refreshNavigation(), renderSecuritySection()]); DOMElements.navigationList.querySelector('#nav-item-all').click(); }
        init();
    });
    </script>
</body>
</html>
EOF

    echo "--> 正在生成登录页 public/login.html..."
cat << 'EOF' > public/login.html
<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>后台登录 - 图片画廊</title>
    <script src="https://cdn.tailwindcss.com"></script>
    <style> body { background-color: #f0fdf4; } .hidden { display: none; } </style>
</head>
<body class="antialiased text-green-900">
    <div class="min-h-screen flex items-center justify-center">
        <div class="max-w-md w-full bg-white p-8 rounded-lg shadow-lg">
            <h1 class="text-3xl font-bold text-center text-green-900 mb-6">后台管理登录</h1>
            <div id="error-message-creds" class="hidden bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded relative mb-4" role="alert">
                <strong class="font-bold">登录失败！</strong>
                <span class="block sm:inline">用户名或密码不正确。</span>
            </div>
            <div id="error-message-tfa" class="hidden bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded relative mb-4" role="alert">
                <strong class="font-bold">验证失败！</strong>
                <span class="block sm:inline">两步验证码(2FA)不正确。</span>
            </div>
            <form action="/api/login" method="POST">
                <div class="mb-4">
                    <label for="username" class="block text-green-800 text-sm font-bold mb-2">用户名</label>
                    <input type="text" id="username" name="username" required class="shadow appearance-none border rounded w-full py-2 px-3 text-gray-700 leading-tight focus:outline-none focus:ring-2 focus:ring-green-500">
                </div>
                <div class="mb-4">
                    <label for="password" class="block text-green-800 text-sm font-bold mb-2">密码</label>
                    <input type="password" id="password" name="password" required class="shadow appearance-none border rounded w-full py-2 px-3 text-gray-700 mb-3 leading-tight focus:outline-none focus:ring-2 focus:ring-green-500">
                </div>
                <div id="tfa-input-container" class="mb-6 hidden">
                    <label for="tfa_token" class="block text-green-800 text-sm font-bold mb-2">两步验证码 (2FA)</label>
                    <input type="text" id="tfa_token" name="tfa_token" placeholder="已启用2FA，请输入验证码" autocomplete="off" class="shadow appearance-none border rounded w-full py-2 px-3 text-gray-700 leading-tight focus:outline-none focus:ring-2 focus:ring-green-500">
                </div>
                <div class="flex items-center justify-between">
                    <button type="submit" class="w-full bg-green-600 hover:bg-green-700 text-white font-bold py-2 px-4 rounded-lg focus:outline-none focus:shadow-outline transition-colors"> 登 录 </button>
                </div>
            </form>
        </div>
    </div>
    <script>
        document.addEventListener('DOMContentLoaded', () => {
            fetch('/api/2fa/is-enabled')
                .then(response => {
                    if (!response.ok) throw new Error('Network response was not ok');
                    return response.json();
                })
                .then(data => {
                    if (data.enabled) {
                        const tfaContainer = document.getElementById('tfa-input-container');
                        const tfaInput = document.getElementById('tfa_token');
                        tfaContainer.classList.remove('hidden');
                        tfaInput.required = true;
                    }
                })
                .catch(err => {
                    console.error('无法检查2FA状态:', err);
                });
        });

        const urlParams = new URLSearchParams(window.location.search);
        const error = urlParams.get('error');
        if (error === '1') {
            document.getElementById('error-message-creds').classList.remove('hidden');
        } else if (error === '2') {
            const tfaError = document.getElementById('error-message-tfa');
            tfaError.querySelector('span').textContent = '两步验证码(2FA)是必需的。';
            tfaError.classList.remove('hidden');
        } else if (error === '3') {
            const tfaError = document.getElementById('error-message-tfa');
            tfaError.querySelector('span').textContent = '两步验证码(2FA)不正确。';
            tfaError.classList.remove('hidden');
        }
    </script>
</body>
</html>
EOF

    echo -e "${GREEN}--- 所有项目文件已成功生成在 ${INSTALL_DIR} ---${NC}"
    return 0
}

# --- 管理菜单功能 (以下部分无改动，保持原样) ---
run_update_procedure() {
    echo -e "${GREEN}--- 开始覆盖更新(保留数据) ---${NC}"
    cd "${INSTALL_DIR}" || { echo -e "${RED}错误: 无法进入安装目录 '${INSTALL_DIR}'。${NC}"; return 1; }
    
    overwrite_app_files
    
    echo -e "${YELLOW}--> 正在检查并安装依赖 (npm install)...${NC}"
    if npm install; then
        echo -e "${GREEN}--> 依赖安装成功！${NC}"
    else
        echo -e "${RED}--> npm install 失败，请检查错误日志。${NC}"
    fi

    echo -e "${YELLOW}--> 正在重启应用以应用更新...${NC}"
    restart_app
    echo -e "${GREEN}--- 覆盖更新完成！ ---${NC}"
}

run_fresh_install_procedure() {
    echo -e "${GREEN}--- 开始全新安装 ---${NC}"
    if [ -d "${INSTALL_DIR}" ]; then
        echo -e "${YELLOW}--> 正在清理旧的应用目录...${NC}"
        rm -rf "${INSTALL_DIR}"
    fi

    generate_files || return 1
    
    cd "${INSTALL_DIR}" || { echo -e "${RED}错误: 无法进入安装目录 '${INSTALL_DIR}'。${NC}"; return 1; }

    echo -e "${YELLOW}--- 安全设置向导 ---${NC}"
    read -p "请输入新的后台管理员用户名 [默认为 admin]: " new_username
    new_username=${new_username:-admin}
    
    local new_password
    while true; do
        read -s -p "请输入新的后台管理员密码 (必须填写): " new_password; echo
        read -s -p "请再次输入密码以确认: " new_password_confirm; echo
        if [ "$new_password" == "$new_password_confirm" ] && [ -n "$new_password" ]; then
            break
        else
            echo -e "${RED}密码不匹配或为空，请重试。${NC}"
        fi
    done
    
    local jwt_secret
    jwt_secret=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 64 | head -n 1)
    
    echo "--> 正在创建 .env 配置文件..."
    (
        echo "PORT=3000"
        echo "ADMIN_USERNAME=${new_username}"
        echo "ADMIN_PASSWORD=${new_password}"
        echo "JWT_SECRET=${jwt_secret}"
    ) > .env
    echo -e "${GREEN}--> .env 配置文件创建成功！${NC}"
    
    echo -e "${YELLOW}--> 正在安装项目依赖 (npm install)，这可能需要几分钟...${NC}"
    if npm install; then
        echo -e "${GREEN}--> 项目依赖安装成功！${NC}"
    else
        echo -e "${RED}--> npm install 失败，请检查错误日志。${NC}"
        return 1
    fi

    echo -e "${GREEN}--- 全新安装完成！正在自动启动应用... ---${NC}"
    start_app
}

install_app() {
    echo -e "${YELLOW}--- 1. 安装或修复应用 ---${NC}"
    echo "--> 正在检查系统环境和核心依赖..."
    
    local sudo_cmd=""
    if [ "$EUID" -ne 0 ]; then
        if command -v sudo &> /dev/null; then
            sudo_cmd="sudo"
        else
            echo -e "${RED}错误：此脚本需要以 root 用户身份运行，或者需要安装 'sudo' 工具才能继续。${NC}"
            return 1
        fi
    fi

    check_and_install_deps "Node.js & npm" "nodejs npm" "node" "${sudo_cmd}" || return 1
    check_and_install_deps "编译工具(for sharp)" "build-essential" "make" "${sudo_cmd}" || return 1

    if ! command -v pm2 &> /dev/null; then
        echo -e "${YELLOW}--> 检测到 PM2 未安装，将通过 npm 全局安装...${NC}"
        if ${sudo_cmd} npm install -g pm2; then
            echo -e "${GREEN}--> PM2 安装成功！${NC}"
        else
            echo -e "${RED}--> PM2 安装失败，请检查 npm 是否配置正确。${NC}"
            return 1
        fi
    fi
    echo -e "${GREEN}--> 核心依赖检查完毕。${NC}"

    if [ -f "${INSTALL_DIR}/.env" ]; then
        echo -e "${YELLOW}--> 检测到应用已安装。请选择您的操作：${NC}"
        echo ""
        echo -e "  [1] ${GREEN}覆盖更新 (推荐)${NC} - 只更新程序，保留所有数据和配置。"
        echo -e "  [2] ${RED}全新覆盖安装 (危险)${NC} - 删除现有应用，包括所有数据，然后全新安装。"
        echo "  [0] 返回主菜单"
        echo ""
        local update_choice
        read -p "请输入你的选择 [0-2]: " update_choice

        case $update_choice in
            1)
                run_update_procedure
                ;;
            2)
                echo -e "${RED}警告：此操作将永久删除现有应用的所有数据和配置！${NC}"
                read -p "请输入 '确认删除' 以继续: " confirmation
                if [ "$confirmation" == "确认删除" ]; then
                    run_fresh_install_procedure
                else
                    echo -e "${YELLOW}输入不正确，操作已取消。${NC}"
                fi
                ;;
            0)
                echo "操作已取消。"
                return
                ;;
            *)
                echo -e "${RED}无效输入...${NC}"
                ;;
        esac
    else
        echo -e "${YELLOW}--> 未检测到现有安装，将开始全新安装流程...${NC}"
        run_fresh_install_procedure
    fi
}

check_and_install_deps() {
    local dep_to_check=$1
    local package_name=$2
    local command_to_check=$3
    local sudo_cmd=$4
    
    if command -v "$command_to_check" &> /dev/null; then
        return 0
    fi
    
    echo -e "${YELLOW}--> 检测到核心依赖 '${dep_to_check}' 未安装，正在尝试自动安装...${NC}"
    
    local pm_cmd=""

    if command -v apt-get &> /dev/null; then
        pm_cmd="apt-get install -y"
        echo "--> 检测到 APT 包管理器，正在更新..."
        ${sudo_cmd} apt-get update -y
    elif command -v dnf &> /dev/null; then
        pm_cmd="dnf install -y"
        echo "--> 检测到 DNF 包管理器..."
    elif command -v yum &> /dev/null; then
        pm_cmd="yum install -y"
        echo "--> 检测到 YUM 包管理器..."
    else
        echo -e "${RED}错误: 未找到 apt, dnf 或 yum 包管理器。请手动安装 '${dep_to_check}' (${package_name})。${NC}"
        return 1
    fi

    echo "--> 准备执行: ${sudo_cmd} ${pm_cmd} ${package_name}"
    if eval "${sudo_cmd} ${pm_cmd} ${package_name}"; then
        echo -e "${GREEN}--> '${dep_to_check}' 安装成功！${NC}"
        return 0
    else
        echo -e "${RED}--> 自动安装 '${dep_to_check}' 失败。请检查错误并手动安装。${NC}"
        return 1
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
        if [ -z "${SERVER_IP}" ]; then SERVER_IP="127.0.0.1"; fi
        
        local PORT; PORT=$(grep 'PORT=' .env | cut -d '=' -f2)
        local ADMIN_USER; ADMIN_USER=$(grep 'ADMIN_USERNAME=' .env | cut -d '=' -f2)
        
        if command -v pm2 &> /dev/null && pm2 id "$APP_NAME" &> /dev/null; then
            local pm2_status; pm2_status=$(pm2 show "$APP_NAME" | grep 'status' | awk '{print $4}')
            if [ "$pm2_status" == "online" ]; then
                printf "  %-15s %b%s%b\n" "运行状态:" "${GREEN}" "在线 (Online)" "${NC}"
            else
                printf "  %-15s %b%s%b\n" "运行状态:" "${RED}" "离线 (Offline)" "${NC}"
            fi
            local log_path; log_path=$(pm2 show "$APP_NAME" | grep 'out log path' | awk '{print $6}')
            printf "  %-15s %b%s%b\n" "日志文件:" "${BLUE}" "${log_path}" "${NC}"
        else
            printf "  %-15s %b%s%b\n" "运行状态:" "${YELLOW}" "未知 (PM2未运行或应用未被管理)" "${NC}"
            printf "  %-15s %b%s%b\n" "日志文件:" "${YELLOW}" "未知 (PM2未管理)" "${NC}"
        fi

        if [ -f "data/config.json" ]; then
             if grep -q "tfa" "data/config.json"; then
                printf "  %-15s %b%s%b\n" "2FA 状态:" "${GREEN}" "已启用" "${NC}"
            else
                printf "  %-15s %b%s%b\n" "2FA 状态:" "${RED}" "未启用" "${NC}"
            fi
        else
             printf "  %-15s %b%s%b\n" "2FA 状态:" "${RED}" "未启用" "${NC}"
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

start_app() {
    echo -e "${GREEN}--- 正在启动应用... ---${NC}"
    [ ! -d "${INSTALL_DIR}" ] || [ ! -f "${INSTALL_DIR}/.env" ] && { echo -e "${RED}错误: 应用未安装或 .env 文件不存在。请先运行安装程序 (选项1)。${NC}"; return 1; }
    cd "${INSTALL_DIR}" || return 1
    
    local sudo_cmd=""
    if [ "$EUID" -ne 0 ]; then
        if command -v sudo &> /dev/null; then sudo_cmd="sudo"; fi
    fi
    
    ${sudo_cmd} pm2 start server.js --name "$APP_NAME"
    ${sudo_cmd} pm2 startup
    ${sudo_cmd} pm2 save --force
    echo -e "${GREEN}--- 应用已启动！---${NC}"
}

stop_app() {
    echo -e "${YELLOW}--- 正在停止应用... ---${NC}"
    [ ! -d "${INSTALL_DIR}" ] && { echo -e "${RED}错误: 应用未安装。${NC}"; return 1; }
    
    local sudo_cmd=""
    if [ "$EUID" -ne 0 ]; then
        if command -v sudo &> /dev/null; then sudo_cmd="sudo"; fi
    fi
    
    ${sudo_cmd} pm2 stop "$APP_NAME"
    echo -e "${GREEN}--- 应用已停止！---${NC}"
}

restart_app() {
    echo -e "${GREEN}--- 正在重启应用... ---${NC}"
    [ ! -d "${INSTALL_DIR}" ] && { echo -e "${RED}错误: 应用未安装。${NC}"; return 1; }
    
    local sudo_cmd=""
    if [ "$EUID" -ne 0 ]; then
        if command -v sudo &> /dev/null; then sudo_cmd="sudo"; fi
    fi
    
    ${sudo_cmd} pm2 restart "$APP_NAME"
    echo -e "${GREEN}--- 应用已重启！---${NC}"
}

view_logs() {
    echo -e "${YELLOW}--- 显示应用日志 (按 Ctrl+C 退出)... ---${NC}"
    [ ! -d "${INSTALL_DIR}" ] && { echo -e "${RED}错误: 应用未安装。${NC}"; return 1; }
    
    local sudo_cmd=""
    if [ "$EUID" -ne 0 ]; then
        if command -v sudo &> /dev/null; then sudo_cmd="sudo"; fi
    fi
    
    ${sudo_cmd} pm2 logs "$APP_NAME"
}

manage_credentials() {
    echo -e "${YELLOW}--- 修改后台配置 ---${NC}"
    [ ! -d "${INSTALL_DIR}" ] || [ ! -f "${INSTALL_DIR}/.env" ] && { echo -e "${RED}错误: 应用未安装或 .env 文件不存在。${NC}"; return 1; }
    cd "${INSTALL_DIR}" || return 1

    local CURRENT_USER; CURRENT_USER=$(grep 'ADMIN_USERNAME=' .env | cut -d '=' -f2)
    echo "当前用户名: ${CURRENT_USER}"
    read -p "请输入新的用户名 (留空则不修改): " new_username
    
    read -s -p "请输入新的密码 (留空则不修改): " new_password; echo
    
    if [ -z "$new_username" ] && [ -z "$new_password" ]; then
        echo -e "${YELLOW}未做任何修改。${NC}"
        return
    fi
    
    if [ -n "$new_username" ]; then
        sed -i "/^ADMIN_USERNAME=/c\\ADMIN_USERNAME=${new_username}" .env
        echo -e "${GREEN}用户名已更新为: ${new_username}${NC}"
    fi
    
    if [ -n "$new_password" ]; then
        sed -i "/^ADMIN_PASSWORD=/c\\ADMIN_PASSWORD=${new_password}" .env
        echo -e "${GREEN}密码已更新。${NC}"
    fi
    
    echo -e "${YELLOW}正在重启应用以使新配置生效...${NC}"
    restart_app
}

manage_port() {
    echo -e "${YELLOW}--- 修改应用端口 ---${NC}"
    [ ! -d "${INSTALL_DIR}" ] || [ ! -f "${INSTALL_DIR}/.env" ] && { echo -e "${RED}错误: 应用未安装或 .env 文件不存在。${NC}"; return 1; }
    
    local sudo_cmd=""
    if [ "$EUID" -ne 0 ] && command -v sudo &>/dev/null; then sudo_cmd="sudo"; fi
    check_and_install_deps "lsof" "lsof" "lsof" "${sudo_cmd}" || return 1
    
    cd "${INSTALL_DIR}" || return 1
    local CURRENT_PORT; CURRENT_PORT=$(grep 'PORT=' .env | cut -d '=' -f2)
    echo "当前端口: ${CURRENT_PORT}"

    local new_port
    while true; do
        read -p "请输入新的端口号 (推荐 1024-65535): " new_port
        if ! [[ "$new_port" =~ ^[0-9]+$ ]] || [ "$new_port" -lt 1 ] || [ "$new_port" -gt 65535 ]; then
            echo -e "${RED}错误: 请输入一个 1-65535 之间的有效数字。${NC}"
            continue
        fi

        if lsof -i :"$new_port" >/dev/null; then
            echo -e "${RED}错误: 端口 ${new_port} 已被占用，请选择其他端口。${NC}"
            continue
        fi
        
        break
    done

    sed -i "/^PORT=/c\\PORT=${new_port}" .env
    echo -e "${GREEN}端口已成功更新为: ${new_port}${NC}"
    echo -e "${YELLOW}正在重启应用以使新端口生效...${NC}"
    restart_app
}

manage_2fa() {
    echo -e "${YELLOW}--- 管理 2FA (双因素认证) ---${NC}"
    [ ! -d "${INSTALL_DIR}" ] || [ ! -f "${INSTALL_DIR}/.env" ] && { echo -e "${RED}错误: 应用未安装。${NC}"; return 1; }
    
    local config_file="${INSTALL_DIR}/data/config.json"
    local tfa_enabled=false
    if [ -f "$config_file" ] && grep -q "tfa" "$config_file"; then
        tfa_enabled=true
    fi

    if [ "$tfa_enabled" = true ]; then
        echo -e "当前 2FA 状态: ${GREEN}已启用${NC}"
        read -p "您想 [1] 禁用 2FA 还是 [2] 强制重置 2FA? (输入其他任意键取消): " tfa_choice
        if [[ "$tfa_choice" == "1" || "$tfa_choice" == "2" ]]; then
            echo -e "${YELLOW}正在移除 2FA 配置...${NC}"
            rm -f "$config_file"
            echo -e "${GREEN}2FA 配置已移除。${NC}"
            echo -e "${YELLOW}请注意：这仅移除了服务器端的密钥。您可能需要手动从您的 Authenticator 应用中删除旧的条目。${NC}"
            echo -e "${YELLOW}正在重启应用...${NC}"
            restart_app
        else
            echo -e "${YELLOW}操作已取消。${NC}"
        fi
    else
        echo -e "当前 2FA 状态: ${RED}未启用${NC}"
        echo -e "${YELLOW}要启用 2FA，请登录后台管理页面，在“安全”区域进行设置。${NC}"
    fi
}

backup_data() {
    echo -e "${YELLOW}--- 开始数据备份 ---${NC}"
    [ ! -d "${INSTALL_DIR}" ] && { echo -e "${RED}错误: 应用未安装，无法备份。${NC}"; return 1; }

    mkdir -p "${BACKUP_DIR}"
    local TIMESTAMP; TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")
    local BACKUP_FILE="${BACKUP_DIR}/image-gallery-backup-${TIMESTAMP}.tar.gz"

    echo "--> 需要备份的目录:"
    echo "    - ${INSTALL_DIR}/data"
    echo "    - ${INSTALL_DIR}/public/uploads"
    echo "    - ${INSTALL_DIR}/.env"
    
    echo "--> 正在创建备份文件: ${BACKUP_FILE}..."
    if tar -czf "${BACKUP_FILE}" -C "${INSTALL_DIR}" data public/uploads .env; then
        echo -e "${GREEN}--- 备份成功！---${NC}"
        echo -e "备份文件已保存至: ${BLUE}${BACKUP_FILE}${NC}"
    else
        echo -e "${RED}--- 备份失败！---${NC}"
        echo -e "请检查权限和可用磁盘空间。"
    fi
}

restore_data() {
    echo -e "${YELLOW}--- 开始数据恢复 ---${NC}"
    [ ! -d "${BACKUP_DIR}" ] || [ -z "$(ls -A ${BACKUP_DIR})" ] && { echo -e "${RED}错误: 找不到备份目录或备份目录为空。${NC}"; return 1; }

    echo -e "${RED}========================= 数据恢复警告 =========================${NC}"
    echo -e "${RED}此操作将【覆盖】当前所有的图片、数据和配置！${NC}"
    echo -e "${RED}它会用您选择的备份文件替换以下所有内容:${NC}"
    echo -e "${RED}  - ${INSTALL_DIR}/data (所有数据库文件)${NC}"
    echo -e "${RED}  - ${INSTALL_DIR}/public/uploads (所有上传的图片)${NC}"
    echo -e "${RED}  - ${INSTALL_DIR}/.env (所有配置，包括密码和端口)${NC}"
    echo -e "${RED}此操作【无法撤销】！请确保您选择了正确的备份文件。${NC}"
    echo -e "${RED}==============================================================${NC}"
    
    local confirm
    read -p "$(echo -e "请输入 '我确认覆盖' 来继续: ")" confirm
    if [ "$confirm" != "我确认覆盖" ]; then
        echo -e "${YELLOW}输入不正确，操作已取消。${NC}"
        return
    fi
    
    echo "--> 可用的备份文件:"
    select backup_file in "${BACKUP_DIR}"/*.tar.gz; do
        if [ -n "$backup_file" ]; then
            break
        else
            echo "无效的选择。"
        fi
    done

    echo "--> 您选择了: ${backup_file}"
    read -p "$(echo -e "最后确认，是否使用此文件进行恢复? ${PROMPT_Y}: ")" final_confirm
    if [[ "$final_confirm" != "y" && "$final_confirm" != "Y" ]]; then
        echo -e "${YELLOW}操作已取消。${NC}"
        return
    fi

    echo "--> 正在停止应用..."
    stop_app
    
    echo "--> 正在清理旧数据..."
    rm -rf "${INSTALL_DIR}/data" "${INSTALL_DIR}/public/uploads" "${INSTALL_DIR}/.env"

    echo "--> 正在从备份文件中恢复..."
    if tar -xzf "${backup_file}" -C "${INSTALL_DIR}"; then
        echo -e "${GREEN}--- 恢复成功！---${NC}"
        echo "--> 正在重启应用..."
        start_app
    else
        echo -e "${RED}--- 恢复失败！---${NC}"
        echo "恢复过程中发生错误。应用当前可能处于不稳定状态。建议重新安装或手动检查。"
    fi
}

uninstall_app() {
    echo -e "${RED}========================= 彻底卸载警告 =========================${NC}"
    echo -e "${RED}此操作将执行以下动作，且【无法撤销】:${NC}"
    echo -e "${RED}  1. 从 PM2 进程管理器中移除 '${APP_NAME}' 应用。${NC}"
    echo -e "${RED}  2. 永久删除整个应用目录: ${YELLOW}${INSTALL_DIR}${NC}"
    echo -e "${RED}     (包括所有程序、配置、已上传的图片、缓存和数据库文件)${NC}"
    echo -e "${YELLOW}  注意: 此操作不会删除备份目录 (${BACKUP_DIR})。${NC}"
    echo -e "${RED}==============================================================${NC}"
    
    local confirm
    read -p "$(echo -e "${YELLOW}您是否完全理解以上后果并确认要彻底卸载? ${PROMPT_Y}: ")" confirm
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        echo "--> 正在从 PM2 中删除应用..."
        local sudo_cmd=""
        if [ "$EUID" -ne 0 ] && command -v sudo &>/dev/null; then sudo_cmd="sudo"; fi
        if command -v pm2 &> /dev/null; then ${sudo_cmd} pm2 delete "$APP_NAME" &> /dev/null; ${sudo_cmd} pm2 save --force &> /dev/null; fi
        
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
    echo -e "${YELLOW}---------------------- 可用操作 ----------------------${NC}"
    echo ""
    echo -e " ${GREEN}【基础操作】${NC}"
    echo -e "   1. 安装 / 更新应用"
    echo -e "   2. 启动应用"
    echo -e "   3. 停止应用"
    echo -e "   4. 重启应用"
    echo ""
    echo -e " ${BLUE}【配置与管理】${NC}"
    echo -e "   5. 刷新状态"
    echo -e "   6. 修改后台用户/密码"
    echo -e "   7. 修改应用端口"
    echo -e "   8. 管理 2FA"
    echo ""
    echo -e " ${YELLOW}【维护与危险操作】${NC}"
    echo -e "   9. 查看实时日志"
    echo -e "   10. 数据备份"
    echo -e "   11. ${GREEN}数据恢复${NC}"
    echo -e "   12. ${RED}彻底卸载应用${NC}"
    echo ""
    echo -e "   0. 退出脚本"
    echo ""
    echo -e "${YELLOW}----------------------------------------------------${NC}"
    local choice
    read -p "请输入你的选择 [0-12]: " choice
    
    case $choice in
        1) install_app ;;
        2) start_app ;;
        3) stop_app ;;
        4) restart_app ;;
        5) show_menu ;;
        6) manage_credentials ;;
        7) manage_port ;;
        8) manage_2fa ;;
        9) view_logs ;;
        10) backup_data ;;
        11) restore_data ;;
        12) uninstall_app ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效输入...${NC}" ;;
    esac

    if [[ "$choice" != "0" && "$choice" != "5" ]]; then
        read -n 1 -s -r -p "按任意键返回主菜单..."
    fi
}

# --- 脚本主入口 ---
while true; do
    show_menu
done
