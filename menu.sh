#!/bin/bash

# =================================================================
#   图片画廊 专业版 - 一体化部署与管理脚本 (v16.0 终极版)
#
#   作者: 编码助手 (经 Gemini Pro 优化)
#   功能: 采用全新异步任务队列，稳定实现所有高级功能。
# =================================================================

# --- 配置 ---
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

APP_NAME="image-gallery"
INSTALL_DIR=$(pwd)/image-gallery-app

# --- 核心功能：文件生成 ---
generate_files() {
    echo -e "${YELLOW}--> 正在创建项目目录结构: ${INSTALL_DIR}${NC}"
    mkdir -p "${INSTALL_DIR}/public/uploads"
    mkdir -p "${INSTALL_DIR}/public/cache"
    mkdir -p "${INSTALL_DIR}/data"
    cd "${INSTALL_DIR}" || exit

    echo "--> 正在生成 data/categories.json..."
cat << 'EOF' > data/categories.json
[
  "未分类"
]
EOF

    echo "--> 正在生成 package.json (已增加 sharp 依赖)..."
cat << 'EOF' > package.json
{
  "name": "image-gallery-pro",
  "version": "7.0.0",
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
    "sharp": "^0.33.1",
    "uuid": "^8.3.2"
  }
}
EOF

    echo "--> 正在生成后端服务器 server.js (已增加同名文件检查API)..."
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

app.use(bodyParser.json());
app.use(bodyParser.urlencoded({ extended: true }));
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
    const { category, search } = req.query;
    if (search) {
        const searchTerm = search.toLowerCase();
        images = images.filter(img => (img.originalFilename && img.originalFilename.toLowerCase().includes(searchTerm)) || (img.description && img.description.toLowerCase().includes(searchTerm)));
    }
    if (category && category !== 'all' && category !== 'random') {
        images = images.filter(img => img.category === category);
    } else if (category === 'random') {
        images.sort(() => 0.5 - Math.random());
    }
    res.json(images.sort((a,b) => new Date(b.uploadedAt) - new Date(a.uploadedAt)));
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
    const images = await readDB(dbPath);
    const existingFilenames = new Set(images.map(img => img.originalFilename));
    const duplicates = filenames.filter(name => existingFilenames.has(name));
    res.json({ duplicates });
});

apiAdminRouter.post('/upload', upload.single('image'), async (req, res) => {
    if (!req.file) return res.status(400).json({ message: '没有选择文件。' });
    try {
        const metadata = await sharp(req.file.path).metadata();
        const images = await readDB(dbPath);
        
        let originalFilename = req.file.originalname;
        const existingFilenames = new Set(images.map(img => img.originalFilename));
        if (existingFilenames.has(originalFilename)) {
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

    echo "--> 正在生成主画廊 public/index.html (等高列瀑布流引擎)..."
cat << 'EOF' > public/index.html
<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0"><title>图片画廊</title><meta name="description" content="一个展示精彩瞬间的图片画廊。">
    <link rel="preconnect" href="https://fonts.googleapis.com"><link rel="preconnect" href="https://fonts.gstatic.com" crossorigin><link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;700&family=Noto+Sans+SC:wght@400;500;700&display=swap" rel="stylesheet">
    <script src="https://cdn.tailwindcss.com"></script>
    <style>
        body { font-family: 'Inter', 'Noto Sans SC', sans-serif; background-color: #f0fdf4; color: #14532d; display: flex; flex-direction: column; min-height: 100vh; }
        body.lightbox-open { overflow: hidden; }
        .filter-btn { padding: 0.5rem 1rem; border-radius: 9999px; font-weight: 500; transition: all 0.2s ease; border: 1px solid transparent; cursor: pointer; }
        .filter-btn:hover { background-color: #dcfce7; }
        .filter-btn.active { background-color: #22c55e; color: white; border-color: #16a34a; }
        .gallery-container { display: flex; gap: 10px; }
        .gallery-column { display: flex; flex-direction: column; gap: 10px; flex-basis: 0; flex-grow: 1; }
        .gallery-item { display: block; position: relative; overflow: hidden; border-radius: 0.5rem; background-color: #e4e4e7; line-height: 0; }
        .gallery-item img { width: 100%; height: auto; object-fit: cover; transition: transform 0.3s ease, filter 0.3s ease; }
        .gallery-item:hover img { transform: scale(1.05); filter: brightness(0.85); }
        .lightbox { position: fixed; top: 0; left: 0; width: 100%; height: 100%; background-color: rgba(0, 0, 0, 0.9); display: none; justify-content: center; align-items: center; z-index: 1000; opacity: 0; transition: opacity 0.3s ease; }
        .lightbox.active { display: flex; opacity: 1; }
        .lightbox-image { max-width: 85%; max-height: 85%; display: block; object-fit: contain; }
        .lightbox-btn { position: absolute; top: 50%; transform: translateY(-50%); background-color: rgba(255,255,255,0.1); color: white; border: none; font-size: 2.5rem; cursor: pointer; padding: 0.5rem 1rem; border-radius: 0.5rem; transition: background-color 0.2s; }
        .lb-prev { left: 1rem; } .lb-next { right: 1rem; } .lb-close { top: 1rem; right: 1rem; font-size: 2rem; }
        .lb-counter { position: absolute; top: 1.5rem; left: 50%; transform: translateX(-50%); color: white; font-size: 1rem; background-color: rgba(0,0,0,0.3); padding: 0.25rem 0.75rem; border-radius: 9999px; }
        .back-to-top { position: fixed; bottom: 2rem; right: 2rem; background-color: #22c55e; color: white; width: 3rem; height: 3rem; border-radius: 9999px; display: flex; align-items: center; justify-content: center; box-shadow: 0 4px 8px rgba(0,0,0,0.2); cursor: pointer; opacity: 0; visibility: hidden; transform: translateY(20px); transition: all 0.3s ease; }
        .back-to-top.visible { opacity: 1; visibility: visible; transform: translateY(0); }
        .lb-download { position: absolute; bottom: 1rem; right: 1rem; background-color: #22c55e; color: white; border: none; padding: 0.5rem 1rem; border-radius: 0.5rem; cursor: pointer; transition: background-color 0.2s; font-size: 1rem; text-decoration: none; }
        .lb-download:hover { background-color: #16a34a; }
        .header-sticky { padding-top: 1rem; padding-bottom: 1rem; background-color: rgba(240, 253, 244, 0.8); backdrop-filter: blur(8px); position: sticky; top: 0; z-index: 40; box-shadow: 0 4px 6px -1px rgb(0 0 0 / 0.1), 0 2px 4px -2px rgb(0 0 0 / 0.1); transition: padding 0.3s ease-in-out, background-color 0.3s ease-in-out; }
    </style>
</head>
<body class="antialiased">
    <header class="text-center header-sticky">
        <h1 class="text-4xl md:text-5xl font-bold text-green-900 mb-6">图片画廊</h1>
        <div class="max-w-4xl mx-auto mb-4 px-4"><div class="relative"><div class="absolute inset-y-0 left-0 pl-3 flex items-center pointer-events-none"><svg class="w-5 h-5 text-gray-400" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20" fill="currentColor"><path fill-rule="evenodd" d="M8 4a4 4 0 100 8 4 4 0 000-8zM2 8a6 6 0 1110.89 3.476l4.817 4.817a1 1 0 01-1.414 1.414l-4.816-4.816A6 6 0 012 8z" clip-rule="evenodd" /></svg></div><input type="search" id="search-input" placeholder="搜索图片描述或文件名..." class="block w-full pl-10 pr-3 py-2 border border-gray-300 rounded-full leading-5 bg-white placeholder-gray-500 focus:outline-none focus:placeholder-gray-400 focus:ring-1 focus:ring-green-500 focus:border-green-500 sm:text-sm"></div></div>
        <div id="filter-buttons" class="flex justify-center flex-wrap gap-2 px-4"><button class="filter-btn active" data-filter="all">全部</button><button class="filter-btn" data-filter="random">随机</button></div>
    </header>
    <main class="container mx-auto px-6 py-8 md:py-10 flex-grow">
        <div id="gallery-container" class="gallery-container max-w-7xl mx-auto"></div>
        <div id="loader" class="text-center py-8 text-green-700 hidden">正在加载...</div>
    </main>
    <footer class="text-center py-8 mt-auto border-t border-green-200"><p class="text-green-700">© 2025 图片画廊</p></footer>
    <div class="lightbox"><span class="lb-counter"></span><button class="lightbox-btn lb-close">&times;</button><button class="lightbox-btn lb-prev">&lsaquo;</button><img class="lightbox-image" alt=""><button class="lightbox-btn lb-next">&rsaquo;</button><a href="#" id="lightbox-download-link" download class="lb-download">下载</a></div>
    <a class="back-to-top" title="返回顶部"><svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 19V5M5 12l7-7 7 7"/></svg></a>
    
    <script>
    document.addEventListener('DOMContentLoaded', function () {
        const galleryContainer = document.getElementById('gallery-container'); const loader = document.getElementById('loader'); const searchInput = document.getElementById('search-input'); const filterButtonsContainer = document.getElementById('filter-buttons');
        let currentFilter = 'all'; let currentSearch = ''; let allImageData = []; let filteredData = []; let debounceTimer;

        const ColumnLayout = {
            container: galleryContainer, gap: 10,
            getColumnsCount() { const width = window.innerWidth; if (width >= 1280) return 4; if (width >= 1024) return 3; if (width >= 768) return 2; return 1; },
            render(images) {
                this.container.innerHTML = '';
                if (!images.length) { loader.classList.remove('hidden'); loader.textContent = '没有找到符合条件的图片。'; return; }
                loader.classList.add('hidden');
                const numColumns = this.getColumnsCount();
                const columns = Array.from({ length: numColumns }, () => ({ element: document.createElement('div'), items: [], height: 0 }));
                columns.forEach(col => { col.element.className = 'gallery-column'; this.container.appendChild(col.element); });
                const imagesToDistribute = [...images];
                if (currentFilter !== 'random') { imagesToDistribute.sort((a, b) => (b.height/b.width) - (a.height/a.width)); }
                imagesToDistribute.forEach(image => {
                    let shortestColumn = columns[0];
                    for (let i = 1; i < columns.length; i++) { if (columns[i].height < shortestColumn.height) { shortestColumn = columns[i]; } }
                    const imageAspect = image.height / image.width; shortestColumn.height += imageAspect;
                    const item = document.createElement('a');
                    item.className = 'gallery-item'; item.href = "#"; item.dataset.id = image.id;
                    const webpSrcset = `/image-proxy/${image.filename}?w=400&format=webp 400w, /image-proxy/${image.filename}?w=800&format=webp 800w`;
                    const jpegSrcset = `/image-proxy/${image.filename}?w=400 400w, /image-proxy/${image.filename}?w=800 800w`;
                    item.innerHTML = `<picture><source type="image/webp" srcset="${webpSrcset}"><source type="image/jpeg" srcset="${jpegSrcset}"><img src="/image-proxy/${image.filename}?w=400" alt="${image.description}" loading="lazy"></picture>`;
                    shortestColumn.element.appendChild(item);
                });
            }
        };

        const fetchJSON = async (url) => { const response = await fetch(url); if (!response.ok) throw new Error(`HTTP error! status: ${response.status}`); return response.json(); };
        async function createFilterButtons() { try { const categories = await fetchJSON('/api/public/categories'); filterButtonsContainer.querySelectorAll('.dynamic-filter').forEach(btn => btn.remove()); categories.forEach(category => { const button = document.createElement('button'); button.className = 'filter-btn dynamic-filter'; button.dataset.filter = category; button.textContent = category; filterButtonsContainer.appendChild(button); }); } catch (error) { console.error('无法加载分类按钮:', error); } }
        function applyFiltersAndRender() {
            let dataToProcess = [...allImageData];
            if (currentSearch) { const searchTerm = currentSearch.toLowerCase(); dataToProcess = dataToProcess.filter(item => (item.description && item.description.toLowerCase().includes(searchTerm)) || (item.originalFilename && item.originalFilename.toLowerCase().includes(searchTerm))); }
            if (currentFilter === 'all') { filteredData = dataToProcess;
            } else if (currentFilter === 'random') { for (let i = dataToProcess.length - 1; i > 0; i--) { const j = Math.floor(Math.random() * (i + 1)); [dataToProcess[i], dataToProcess[j]] = [dataToProcess[j], dataToProcess[i]]; } filteredData = dataToProcess;
            } else { filteredData = dataToProcess.filter(item => item.category === currentFilter); }
            ColumnLayout.render(filteredData);
        }
        async function initializeGallery() { loader.classList.remove('hidden'); loader.textContent = '正在加载...'; try { allImageData = await fetchJSON('/api/images'); applyFiltersAndRender(); } catch (error) { console.error('获取图片数据失败:', error); loader.textContent = '加载失败，请刷新页面。'; } }
        const lightbox = document.querySelector('.lightbox'); const lightboxImage = lightbox.querySelector('.lightbox-image'); const lbCounter = lightbox.querySelector('.lb-counter'); const lbDownloadLink = document.getElementById('lightbox-download-link');
        let currentImageIndexInFiltered = 0;
        galleryContainer.addEventListener('click', (e) => {
            e.preventDefault();
            const item = e.target.closest('.gallery-item');
            if (item) {
                currentImageIndexInFiltered = filteredData.findIndex(img => img.id === item.dataset.id);
                if (currentImageIndexInFiltered === -1) return;
                updateLightbox();
                lightbox.classList.add('active'); document.body.classList.add('lightbox-open');
            }
        });
        function updateLightbox() { const currentItem = filteredData[currentImageIndexInFiltered]; if (!currentItem) return; lightboxImage.src = currentItem.src; lightboxImage.alt = currentItem.description; lbCounter.textContent = `${currentImageIndexInFiltered + 1} / ${filteredData.length}`; lbDownloadLink.href = currentItem.src; lbDownloadLink.download = currentItem.originalFilename; }
        function showPrevImage() { currentImageIndexInFiltered = (currentImageIndexInFiltered - 1 + filteredData.length) % filteredData.length; updateLightbox(); }
        function showNextImage() { currentImageIndexInFiltered = (currentImageIndexInFiltered + 1) % filteredData.length; updateLightbox(); }
        function closeLightbox() { lightbox.classList.remove('active'); document.body.classList.remove('lightbox-open'); }
        lightbox.addEventListener('click', (e) => { const target = e.target; if (target.matches('.lb-next')) showNextImage(); else if (target.matches('.lb-prev')) showPrevImage(); else if (target.matches('.lb-close') || target === lightbox) closeLightbox(); });
        document.addEventListener('keydown', (e) => { if (lightbox.classList.contains('active')) { if (e.key === 'ArrowLeft') showPrevImage(); if (e.key === 'ArrowRight') showNextImage(); if (e.key === 'Escape') closeLightbox(); } });
        filterButtonsContainer.addEventListener('click', (e) => { const target = e.target.closest('.filter-btn'); if (!target) return; currentFilter = target.dataset.filter; document.querySelectorAll('.filter-btn').forEach(btn => btn.classList.remove('active')); target.classList.add('active'); applyFiltersAndRender(); });
        searchInput.addEventListener('input', () => { clearTimeout(debounceTimer); debounceTimer = setTimeout(() => { currentSearch = searchInput.value; applyFiltersAndRender(); }, 300); });
        const backToTopBtn = document.querySelector('.back-to-top'); 
        backToTopBtn.addEventListener('click', () => window.scrollTo({ top: 0, behavior: 'smooth' }));
        window.addEventListener('scroll', () => { backToTopBtn.classList.toggle('visible', window.scrollY > 300); });
        window.addEventListener('resize', () => { clearTimeout(debounceTimer); debounceTimer = setTimeout(applyFiltersAndRender, 200); });
        (async function init() { await createFilterButtons(); await initializeGallery(); })();
    });
    </script>
</body>
</html>
EOF

    echo "--> 正在生成后台登录页 public/login.html..."
cat << 'EOF' > public/login.html
<!DOCTYPE html><html lang="zh-CN"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0"><title>后台登录 - 图片画廊</title><script src="https://cdn.tailwindcss.com"></script><style> body { background-color: #f0fdf4; } </style></head><body class="antialiased text-green-900"><div class="min-h-screen flex items-center justify-center"><div class="max-w-md w-full bg-white p-8 rounded-lg shadow-lg"><h1 class="text-3xl font-bold text-center text-green-900 mb-6">后台管理登录</h1><div id="error-message" class="hidden bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded relative mb-4" role="alert"><strong class="font-bold">登录失败！</strong><span class="block sm:inline">用户名或密码不正确。</span></div><form action="/api/login" method="POST"><div class="mb-4"><label for="username" class="block text-green-800 text-sm font-bold mb-2">用户名</label><input type="text" id="username" name="username" required class="shadow appearance-none border rounded w-full py-2 px-3 text-gray-700 leading-tight focus:outline-none focus:ring-2 focus:ring-green-500"></div><div class="mb-6"><label for="password" class="block text-green-800 text-sm font-bold mb-2">密码</label><input type="password" id="password" name="password" required class="shadow appearance-none border rounded w-full py-2 px-3 text-gray-700 mb-3 leading-tight focus:outline-none focus:ring-2 focus:ring-green-500"></div><div class="flex items-center justify-between"><button type="submit" class="w-full bg-green-600 hover:bg-green-700 text-white font-bold py-2 px-4 rounded-lg focus:outline-none focus:shadow-outline transition-colors"> 登 录 </button></div></form></div></div><script> const urlParams = new URLSearchParams(window.location.search); if (urlParams.has('error')) { document.getElementById('error-message').classList.remove('hidden'); } </script></body></html>
EOF

    echo "--> 正在生成后台管理页 public/admin.html (最终版UI)..."
cat << 'EOF' > public/admin.html
<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0"><title>后台管理 - 图片画廊</title>
    <script src="https://cdn.tailwindcss.com"></script>
    <style> body { background-color: #f8fafc; } .modal, .toast, .lightbox { display: none; } .modal.active, .lightbox.active { display: flex; } body.lightbox-open { overflow: hidden; } .category-item.active { background-color: #dcfce7; font-weight: bold; } .toast { position: fixed; top: 1.5rem; right: 1.5rem; z-index: 9999; transform: translateX(120%); transition: transform 0.3s ease-in-out; } .toast.show { transform: translateX(0); } .file-preview-item.upload-success { background-color: #f0fdf4; } .file-preview-item.upload-error { background-color: #fef2f2; } .lightbox { position: fixed; top: 0; left: 0; width: 100%; height: 100%; background-color: rgba(0, 0, 0, 0.9); justify-content: center; align-items: center; z-index: 1000; opacity: 0; visibility: hidden; transition: opacity 0.3s ease; } .lightbox.active { opacity: 1; visibility: visible; } .lightbox-image { max-width: 85%; max-height: 85%; display: block; object-fit: contain; } .lightbox-btn { position: absolute; top: 50%; transform: translateY(-50%); background-color: rgba(255,255,255,0.1); color: white; border: none; font-size: 2.5rem; cursor: pointer; padding: 0.5rem 1rem; border-radius: 0.5rem; transition: background-color 0.2s; } .lb-prev { left: 1rem; } .lb-next { right: 1rem; } .lb-close { top: 1rem; right: 1rem; font-size: 2rem; } .lb-download { position: absolute; bottom: 1rem; right: 1rem; background-color: #22c55e; color: white; border: none; padding: 0.5rem 1rem; border-radius: 0.5rem; cursor: pointer; transition: background-color 0.2s; font-size: 1rem; text-decoration: none; } .lb-download:hover { background-color: #16a34a; } #file-preview-list-wrapper { resize: vertical; overflow: hidden; } </style>
</head>
<body class="antialiased text-slate-800">
    <header class="bg-white shadow-md p-4 flex justify-between items-center sticky top-0 z-20"><h1 class="text-2xl font-bold text-slate-900">内容管理系统</h1><div><a href="/" target="_blank" class="text-green-600 hover:text-green-800 mr-4">查看前台</a><a href="/api/logout" class="bg-red-500 hover:bg-red-700 text-white font-bold py-2 px-4 rounded transition-colors">退出登录</a></div></header>
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
        const showConfirmationModal = (title, bodyHtml) => { return new Promise(resolve => { const footerHtml = `<button type="button" class="modal-cancel-btn bg-gray-300 hover:bg-gray-400 text-black py-2 px-4 rounded">取消</button><button type="button" id="modal-confirm-btn" class="bg-red-600 hover:bg-red-700 text-white py-2 px-4 rounded">继续上传</button>`; showGenericModal(title, bodyHtml, footerHtml); DOMElements.genericModal.querySelector('#modal-confirm-btn').onclick = () => { hideModal(DOMElements.genericModal); resolve(true); }; DOMElements.genericModal.querySelector('.modal-cancel-btn').onclick = () => { hideModal(DOMElements.genericModal); resolve(false); }; }); };
        const hideModal = (modal) => modal.classList.remove('active');
        DOMElements.genericModal.addEventListener('click', e => { if (e.target === DOMElements.genericModal) hideModal(DOMElements.genericModal); });
        DOMElements.editImageModal.addEventListener('click', e => { if (e.target === DOMElements.editImageModal || e.target.closest('.modal-cancel-btn')) hideModal(DOMElements.editImageModal); });
        const handleFileSelection = (fileList) => { const imageFiles = Array.from(fileList).filter(f => f.type.startsWith('image/')); const currentFilenames = new Set(filesToUpload.map(item => item.file.name)); const newFiles = imageFiles.filter(f => !currentFilenames.has(f.name)).map(file => ({ file, description: DOMElements.unifiedDescription.value, userHasTyped: DOMElements.unifiedDescription.value !== '' })); filesToUpload = filesToUpload.concat(newFiles); DOMElements.uploadBtn.disabled = filesToUpload.length === 0; renderFilePreviews(); };
        const renderFilePreviews = () => { if (filesToUpload.length === 0) { DOMElements.filePreviewContainer.classList.add('hidden'); return; } DOMElements.filePreviewList.innerHTML = ''; let totalSize = 0; filesToUpload.forEach((item, index) => { totalSize += item.file.size; const listItem = document.createElement('div'); const tempId = `file-preview-${index}`; listItem.className = 'file-preview-item text-slate-600 border rounded p-2'; listItem.dataset.fileIndex = index; listItem.innerHTML = `<div class="flex items-start"><img class="w-12 h-12 object-cover rounded mr-3 bg-slate-100" id="thumb-${tempId}"><div class="flex-grow"><div class="flex justify-between items-center text-xs mb-1"><p class="truncate pr-2 font-medium">${item.file.name}</p><button type="button" data-index="${index}" class="remove-file-btn text-xl text-red-500 hover:text-red-700 leading-none">&times;</button></div><p class="text-xs text-slate-500">${formatBytes(item.file.size)}</p></div></div><input type="text" data-index="${index}" class="relative w-full text-xs border rounded px-2 py-1 description-input bg-transparent mt-2" placeholder="添加独立描述..." value="${item.description}"><p class="upload-status text-xs text-red-500 mt-1"></p>`; DOMElements.filePreviewList.appendChild(listItem); const reader = new FileReader(); reader.onload = (e) => { document.getElementById(`thumb-${tempId}`).src = e.target.result; }; reader.readAsDataURL(item.file); }); DOMElements.uploadSummary.textContent = `已选择 ${filesToUpload.length} 个文件，总大小: ${formatBytes(totalSize)}`; DOMElements.filePreviewContainer.classList.remove('hidden'); };
        const dz = DOMElements.dropZone; dz.addEventListener('dragover', (e) => { e.preventDefault(); dz.classList.add('bg-green-50', 'border-green-400'); }); dz.addEventListener('dragleave', (e) => dz.classList.remove('bg-green-50', 'border-green-400')); dz.addEventListener('drop', (e) => { e.preventDefault(); dz.classList.remove('bg-green-50', 'border-green-400'); handleFileSelection(e.dataTransfer.files); });
        DOMElements.imageInput.addEventListener('change', (e) => { handleFileSelection(e.target.files); e.target.value = ''; });
        DOMElements.unifiedDescription.addEventListener('input', e => { const unifiedText = e.target.value; document.querySelectorAll('.file-preview-item').forEach(item => { const index = parseInt(item.dataset.fileIndex, 10); if (filesToUpload[index] && !filesToUpload[index].userHasTyped) { item.querySelector('.description-input').value = unifiedText; filesToUpload[index].description = unifiedText; } }); });
        DOMElements.filePreviewList.addEventListener('input', e => { if (e.target.classList.contains('description-input')) { const index = parseInt(e.target.dataset.index, 10); if(filesToUpload[index]) { filesToUpload[index].description = e.target.value; filesToUpload[index].userHasTyped = true; } } });
        DOMElements.filePreviewList.addEventListener('click', e => { if (e.target.classList.contains('remove-file-btn')) { const index = parseInt(e.target.dataset.index, 10); filesToUpload.splice(index, 1); renderFilePreviews(); DOMElements.uploadBtn.disabled = filesToUpload.length === 0; } });
        DOMElements.uploadForm.addEventListener('submit', async (e) => {
            e.preventDefault(); DOMElements.uploadBtn.disabled = true;
            let uploadQueue = [...filesToUpload];
            const processQueue = async () => {
                if (uploadQueue.length === 0) {
                    showToast(`所有任务处理完成。`); DOMElements.uploadBtn.textContent = '上传文件'; filesToUpload = []; DOMElements.imageInput.value = ''; DOMElements.unifiedDescription.value = '';
                    setTimeout(() => { DOMElements.filePreviewContainer.classList.add('hidden'); DOMElements.uploadBtn.disabled = true; }, 2000);
                    await loadImages('all', '全部图片');
                    return;
                }
                DOMElements.uploadBtn.textContent = `正在处理... (${uploadQueue.length})`;
                const item = uploadQueue.shift();
                const originalIndex = filesToUpload.findIndex(f => f.file === item.file);
                const previewItem = DOMElements.filePreviewList.querySelector(`[data-file-index="${originalIndex}"]`);
                const statusEl = previewItem.querySelector('.upload-status');
                try {
                    const checkRes = await apiRequest('/api/admin/check-filenames', { method: 'POST', headers: {'Content-Type': 'application/json'}, body: JSON.stringify({filenames: [item.file.name]}) });
                    if (!checkRes.ok) throw new Error('文件名检查请求失败');
                    const { duplicates } = await checkRes.json();
                    if (duplicates.length > 0) {
                        const userConfirmed = await showConfirmationModal('文件已存在', `文件 "${item.file.name}" 已存在。是否仍然继续上传？<br>(新文件将被自动重命名)`);
                        if (!userConfirmed) { statusEl.textContent = '已取消'; processQueue(); return; }
                    }
                    statusEl.textContent = '上传中...';
                    const formData = new FormData();
                    formData.append('image', item.file); formData.append('category', DOMElements.categorySelect.value); formData.append('description', item.description);
                    const response = await apiRequest('/api/admin/upload', { method: 'POST', body: formData });
                    const result = await response.json();
                    if (response.ok) { previewItem.classList.add('upload-success'); statusEl.textContent = '✅ 上传成功'; } 
                    else { throw new Error(result.message || '上传失败'); }
                } catch (err) { if (err.message !== 'Unauthorized') { statusEl.textContent = `❌ ${err.message}`; previewItem.classList.add('upload-error'); } }
                finally { processQueue(); }
            };
            processQueue();
        });
        async function refreshCategories() { const currentVal = DOMElements.categorySelect.value; await loadAndPopulateCategories(currentVal); await loadAndDisplayCategoriesForManagement(); }
        async function loadAndPopulateCategories(selectedCategory = null) { try { const response = await apiRequest('/api/categories'); const categories = await response.json(); [DOMElements.categorySelect, DOMElements.editCategorySelect].forEach(select => { const currentVal = select.value; select.innerHTML = ''; categories.forEach(cat => select.add(new Option(cat, cat))); select.value = categories.includes(currentVal) ? currentVal : selectedCategory || categories[0]; }); } catch (error) { if (error.message !== 'Unauthorized') console.error('加载分类失败:', error); } }
        async function loadAndDisplayCategoriesForManagement() { try { const response = await apiRequest('/api/categories'); const categories = await response.json(); DOMElements.categoryManagementList.innerHTML = ''; const allCatItem = document.createElement('div'); allCatItem.className = 'category-item flex items-center justify-between p-2 rounded cursor-pointer hover:bg-gray-50 active'; allCatItem.innerHTML = `<span class="category-name flex-grow">全部图片</span>`; DOMElements.categoryManagementList.appendChild(allCatItem); categories.forEach(cat => { const isUncategorized = cat === UNCATEGORIZED; const item = document.createElement('div'); item.className = 'category-item flex items-center justify-between p-2 rounded'; item.innerHTML = `<span class="category-name flex-grow ${isUncategorized ? 'text-slate-500' : 'cursor-pointer hover:bg-gray-50'}">${cat}</span>` + (isUncategorized ? '' : `<div class="space-x-2 flex-shrink-0"><button data-name="${cat}" class="rename-cat-btn text-blue-500 hover:text-blue-700 text-sm">重命名</button><button data-name="${cat}" class="delete-cat-btn text-red-500 hover:red-700 text-sm">删除</button></div>`); DOMElements.categoryManagementList.appendChild(item); }); } catch (error) { if (error.message !== 'Unauthorized') console.error('加载分类管理列表失败:', error); } }
        async function loadImages(category = 'all', categoryName = '全部图片') {
            DOMElements.imageList.innerHTML = ''; DOMElements.imageLoader.classList.remove('hidden');
            try {
                const url = `/api/images?category=${category}&search=${encodeURIComponent(currentSearchTerm)}`;
                const response = await apiRequest(url); adminLoadedImages = await response.json();
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
            card.innerHTML = `<a class="preview-btn h-40 bg-slate-100 flex items-center justify-center cursor-pointer" data-id="${image.id}"><img src="/image-proxy/${image.filename}?w=400" alt="${image.description}" class="max-h-full max-w-full object-contain"></a><div class="p-3 flex-grow flex flex-col"><p class="font-bold text-sm truncate" title="${image.originalFilename}">${image.originalFilename}</p><p class="text-xs text-slate-500 -mt-1 mb-2">${formatBytes(image.size)}</p><p class="text-xs text-slate-500 mb-2">${image.category}</p><p class="text-xs text-slate-600 flex-grow mb-3 break-words">${image.description || '无描述'}</p></div><div class="bg-slate-50 p-2 flex justify-around flex-wrap gap-2"><button data-id="${image.id}" class="preview-btn text-sm bg-gray-500 hover:bg-gray-600 text-white font-bold py-1 px-3 rounded transition-colors whitespace-nowrap">预览</button><a href="${image.src}" download="${image.originalFilename}" class="download-btn text-sm bg-green-600 hover:bg-green-700 text-white font-bold py-1 px-3 rounded transition-colors inline-block whitespace-nowrap" title="下载">下载</a><button data-image='${JSON.stringify(image)}' class="edit-btn text-sm bg-blue-500 hover:bg-blue-600 text-white font-bold py-1 px-3 rounded whitespace-nowrap">编辑</button><button data-id="${image.id}" class="delete-btn text-sm bg-red-500 hover:bg-red-600 text-white font-bold py-1 px-3 rounded whitespace-nowrap">删除</button></div>`;
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
                const confirmed = await showConfirmationModal('确认删除', `<p>确定要删除分类 "<strong>${catName}</strong>" 吗？<br>此分类下的图片将归入 "未分类"。</p>`);
                if(confirmed) { try { const response = await apiRequest('/api/admin/categories', { method: 'DELETE', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ name: catName }) }); if (!response.ok) throw new Error((await response.json()).message); showToast('删除成功'); await Promise.all([refreshCategories(), loadImages('all', '全部图片')]); } catch (error) { showToast(`删除失败: ${error.message}`, 'error'); } }
            } else if (target.classList.contains('category-name')) {
                document.querySelectorAll('.category-item').forEach(el => el.classList.remove('active'));
                target.closest('.category-item').classList.add('active');
                DOMElements.searchInput.value = ''; currentSearchTerm = '';
                const category = target.textContent; await loadImages(category === '全部图片' ? 'all' : category, category);
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
                const confirmed = await showConfirmationModal('确认删除', `<p>确定要永久删除这张图片吗？此操作无法撤销。</p>`);
                if(confirmed) { try { const response = await apiRequest(`/api/admin/images/${imageId}`, { method: 'DELETE' }); if (!response.ok) throw new Error('删除失败'); showToast('图片已删除'); const activeCatItem = document.querySelector('.category-item.active .category-name'); const activeCat = activeCatItem ? activeCatItem.textContent : '全部图片'; await loadImages(activeCat === '全部图片' ? 'all' : activeCat, activeCat); } catch (error) { showToast(error.message, 'error'); } }
            }
        });
        DOMElements.editImageForm.addEventListener('submit', async (e) => {
            e.preventDefault(); const id = document.getElementById('edit-id').value;
            const body = JSON.stringify({ originalFilename: document.getElementById('edit-originalFilename').value, category: DOMElements.editCategorySelect.value, description: document.getElementById('edit-description').value });
            try { const response = await apiRequest(`/api/admin/images/${id}`, { method: 'PUT', headers: { 'Content-Type': 'application/json' }, body }); if (!response.ok) throw new Error((await response.json()).message); hideModal(DOMElements.editImageModal); showToast('更新成功'); const activeCatItem = document.querySelector('.category-item.active .category-name'); const activeCat = activeCatItem ? activeCatItem.textContent : '全部图片'; await loadImages(activeCat === '全部图片' ? 'all' : activeCat, activeCat); } catch (error) { showToast(`更新失败: ${error.message}`, 'error'); }
        });
        async function init() { await Promise.all([ refreshCategories(), loadImages('all', '全部图片') ]); }
        init();
    });
    </script>
</body>
</html>
EOF

    echo -e "${GREEN}--- 所有项目文件已成功生成在 ${INSTALL_DIR} ---${NC}"
}

# --- 管理菜单功能 ---
check_and_install_dep() {
    local dep_name=$1; local check_command=$2; local install_command=$3; local SUDO_CMD=""
    if command -v "$check_command" > /dev/null; then return 0; fi
    echo -e "${YELLOW}--> 检测到核心依赖 '${dep_name}' 未安装。${NC}"
    if [ "$EUID" -ne 0 ]; then
        if command -v sudo > /dev/null; then SUDO_CMD="sudo";
        else echo -e "${RED}错误：当前用户不是root，且未找到'sudo'命令。无法自动安装依赖。${NC}"; echo -e "${YELLOW}请切换到root用户或安装sudo后重试。${NC}"; return 1; fi
    fi
    if command -v apt-get > /dev/null; then
        read -p "是否尝试自动安装? (y/n): " confirm
        if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
            echo "--> 准备执行: ${SUDO_CMD} ${install_command}"; eval "${SUDO_CMD} ${install_command}"
            if ! command -v "$check_command" > /dev/null; then echo -e "${RED}自动安装 '${dep_name}' 失败。请检查错误并手动安装。${NC}"; return 1;
            else echo -e "${GREEN}'${dep_name}' 安装成功！${NC}"; fi
        else echo -e "${YELLOW}已取消自动安装。请手动安装 '${dep_name}'。${NC}"; return 1; fi
    else echo -e "${RED}未找到 'apt-get' 包管理器。请手动安装 '${dep_name}'。${NC}"; return 1; fi
    return 0
}
display_access_info() {
    cd "${INSTALL_DIR}" || return
    local SERVER_IP; SERVER_IP=$(hostname -I | awk '{print $1}')
    if [ -f ".env" ]; then
        set -o allexport; source .env; set +o allexport
        echo -e "${YELLOW}======================================================${NC}"; echo -e "${YELLOW}           应用已就绪！请使用以下信息访问           ${NC}"; echo -e "${YELLOW}======================================================${NC}"
        echo -e "前台画廊地址: ${GREEN}http://${SERVER_IP}:${PORT}${NC}"; echo -e "后台管理地址: ${GREEN}http://${SERVER_IP}:${PORT}/admin${NC}"
        echo -e "后台登录用户: ${BLUE}${ADMIN_USERNAME}${NC}"; echo -e "后台登录密码: ${BLUE}(您设置的密码)${NC}"
        echo -e "${YELLOW}======================================================${NC}"
    fi
}
install_app() {
    echo -e "${GREEN}--- 1. 开始安装或修复应用 ---${NC}"; echo "--> 正在检查系统环境..."
    if ! check_and_install_dep "Node.js & npm" "node" "apt-get update && apt-get install -y nodejs npm"; then return 1; fi
    if ! check_and_install_dep "pm2" "pm2" "npm install -g pm2"; then return 1; fi
    if ! check_and_install_dep "build-essential" "make" "apt-get install -y build-essential"; then return 1; fi
    echo -e "${GREEN}--> 所有核心依赖均已满足。${NC}"; generate_files
    echo -e "${YELLOW}--- 安全设置向导 ---${NC}"; read -p "请输入新的后台管理员用户名 [默认为 admin]: " new_username; new_username=${new_username:-admin}
    local new_password; while true; do read -s -p "请输入新的后台管理员密码 (必须填写): " new_password; echo; read -s -p "请再次输入密码以确认: " new_password_confirm; echo; if [ "$new_password" == "$new_password_confirm" ] && [ -n "$new_password" ]; then break; else echo -e "${RED}密码不匹配或为空，请重试。${NC}"; fi; done
    local jwt_secret; jwt_secret=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 64 | head -n 1)
    echo "--> 正在创建 .env 配置文件..."; ( echo "PORT=3000"; echo "ADMIN_USERNAME=${new_username}"; echo "ADMIN_PASSWORD=${new_password}"; echo "JWT_SECRET=${jwt_secret}"; ) > .env
    echo -e "${GREEN}--> .env 配置文件创建成功！${NC}"; echo "--> 正在安装项目依赖 (npm install)..."; npm install
    echo -e "${GREEN}--- 安装完成！正在自动启动应用... ---${NC}"; start_app; display_access_info
}
start_app() { cd "${INSTALL_DIR}" || exit; echo -e "${GREEN}--- 正在使用 PM2 启动应用... ---${NC}"; if [ ! -f ".env" ]; then echo -e "${RED}错误: .env 文件不存在。请先运行安装程序 (选项1)。${NC}"; return; fi; pm2 start server.js --name "$APP_NAME"; pm2 startup; pm2 save; echo -e "${GREEN}--- 应用已启动！---${NC}"; }
manage_credentials() {
    cd "${INSTALL_DIR}" || exit; echo -e "${YELLOW}--- 修改后台用户名和密码 ---${NC}"; if [ ! -f ".env" ]; then echo -e "${RED}错误: .env 文件不存在。请先安装应用。${NC}"; return; fi
    local CURRENT_USER; CURRENT_USER=$(grep 'ADMIN_USERNAME=' .env | cut -d '=' -f2); echo "当前用户名: ${CURRENT_USER}"; read -p "请输入新的用户名 (留空则不修改): " new_username
    local new_password; read -s -p "请输入新的密码 (留空则不修改): " new_password; echo
    if [ -z "$new_username" ] && [ -z "$new_password" ]; then echo -e "${YELLOW}未做任何修改。${NC}"; return; fi
    if [ -n "$new_username" ]; then sed -i "/^ADMIN_USERNAME=/c\\ADMIN_USERNAME=${new_username}" .env; echo -e "${GREEN}用户名已更新为: ${new_username}${NC}"; fi
    if [ -n "$new_password" ]; then sed -i "/^ADMIN_PASSWORD=/c\\ADMIN_PASSWORD=${new_password}" .env; echo -e "${GREEN}密码已更新。${NC}"; fi
    echo -e "${YELLOW}正在重启应用以使新凭据生效...${NC}"; restart_app
}
stop_app() { echo -e "${YELLOW}--- 停止应用... ---${NC}"; pm2 stop "$APP_NAME"; echo -e "${GREEN}--- 应用已停止！---${NC}"; }
restart_app() { echo -e "${GREEN}--- 重启应用... ---${NC}"; pm2 restart "$APP_NAME"; echo -e "${GREEN}--- 应用已重启！---${NC}"; }
view_logs() { echo -e "${YELLOW}--- 显示应用日志 (按 Ctrl+C 退出)... ---${NC}"; pm2 logs "$APP_NAME"; }
uninstall_app() {
    echo -e "${RED}--- 警告：这将从PM2中移除应用并删除整个项目文件夹！ ---${NC}"; read -p "你确定要继续吗？ (y/n): " confirm
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then echo "--> 正在从 PM2 中删除应用..."; pm2 delete "$APP_NAME"; pm2 save --force; echo "--> 正在删除项目文件夹 ${INSTALL_DIR}..."; rm -rf "${INSTALL_DIR}"; echo -e "${GREEN}应用已彻底卸载。${NC}"; else echo "操作已取消。"; fi
}
show_menu() {
    clear
    echo -e "${YELLOW}======================================================${NC}"; echo -e "${YELLOW}     图片画廊 - 一体化部署与管理脚本 (v16.0)     ${NC}"; echo -e "${YELLOW}======================================================${NC}"
    echo -e " 应用名称: ${GREEN}${APP_NAME}${NC}"; echo -e " 安装路径: ${GREEN}${INSTALL_DIR}${NC}"
    if [ -d "${INSTALL_DIR}" ] && [ -f "${INSTALL_DIR}/.env" ]; then
        local SERVER_IP; SERVER_IP=$(hostname -I | awk '{print $1}')
        local PORT; PORT=$(grep 'PORT=' "${INSTALL_DIR}/.env" | cut -d '=' -f2)
        echo -e " 访问网址: ${GREEN}http://${SERVER_IP}:${PORT}${NC}"
    else echo -e " 访问网址: ${RED}(应用尚未安装)${NC}"; fi
    echo -e "${YELLOW}------------------------------------------------------${NC}"; echo " 1. 安装或修复应用 (首次使用)"; echo " 2. 启动应用"; echo " 3. 停止应用"; echo " 4. 重启应用"; echo " 5. 查看实时日志"; echo " 6. 修改后台用户名和密码"; echo " 7. 彻底卸载应用"; echo " 0. 退出"; echo -e "${YELLOW}------------------------------------------------------${NC}"
    read -p "请输入你的选择 [0-7]: " choice
    case $choice in
        1) install_app ;; 2) start_app; display_access_info ;; 3) stop_app ;; 4) restart_app ;;
        5) view_logs ;; 6) manage_credentials ;; 7) uninstall_app ;; 0) exit 0 ;;
        *) echo -e "${RED}无效输入...${NC}" ;;
    esac
    read -p "按任意键返回主菜单..."
}

# --- 脚本主入口 ---
while true; do
    show_menu
done
