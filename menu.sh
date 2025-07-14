#!/bin/bash

# =================================================================
#   图片画廊 专业版 - 一体化部署与管理脚本 (v7.3 终极安全增强版)
#
#   作者: 编码助手 (经 Gemini Pro 优化)
#   功能: 集成JWT安全认证、全异步IO、交互式安全设置和现代化UI。
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
    mkdir -p "${INSTALL_DIR}/data"
    cd "${INSTALL_DIR}" || exit

    echo "--> 正在生成 data/categories.json..."
cat << 'EOF' > data/categories.json
[
  "未分类",
  "风景",
  "二次元"
]
EOF

    echo "--> 正在生成 package.json (已更新依赖)..."
cat << 'EOF' > package.json
{
  "name": "image-gallery-pro",
  "version": "1.1.0",
  "description": "A secure, full-stack image gallery application.",
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
    "uuid": "^8.3.2"
  }
}
EOF

    echo "--> 正在生成后端服务器 server.js (全异步 + JWT安全认证)..."
cat << 'EOF' > server.js
const express = require('express');
const multer = require('multer');
const bodyParser = require('body-parser');
const path = require('path');
const fs = require('fs').promises;
const { v4: uuidv4 } = require('uuid');
const cookieParser = require('cookie-parser');
const jwt = require('jsonwebtoken');
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

const initializeDirectories = async () => {
    try {
        await fs.mkdir(path.join(__dirname, 'data'), { recursive: true });
        await fs.mkdir(uploadsDir, { recursive: true });
    } catch (error) {
        console.error('初始化目录失败:', error);
        process.exit(1);
    }
};

app.use(bodyParser.json());
app.use(bodyParser.urlencoded({ extended: true }));
app.use(cookieParser());

const readDB = async (filePath) => {
    try {
        await fs.access(filePath);
        const data = await fs.readFile(filePath, 'utf-8');
        if (data.trim() === '') return [];
        return JSON.parse(data);
    } catch (error) {
        if (error.code === 'ENOENT') return []; // 文件不存在，返回空数组
        console.error(`读取或解析JSON文件时出错: ${filePath}`, error);
        return [];
    }
};
const writeDB = async (filePath, data) => {
    try {
        await fs.writeFile(filePath, JSON.stringify(data, null, 2));
    } catch (error) {
        console.error(`写入JSON文件时出错: ${filePath}`, error);
    }
};

const authMiddleware = (isApi) => (req, res, next) => {
    const token = req.cookies[AUTH_TOKEN_NAME];
    if (!token) {
        return isApi
            ? res.status(401).json({ message: '认证失败，请重新登录。' })
            : res.redirect('/login.html');
    }
    try {
        jwt.verify(token, JWT_SECRET);
        next();
    } catch (err) {
        return isApi
            ? res.status(401).json({ message: '认证令牌无效或已过期。' })
            : res.redirect('/login.html');
    }
};

const requirePageAuth = authMiddleware(false);
const requireApiAuth = authMiddleware(true);

app.post('/api/login', (req, res) => {
    const { username, password } = req.body;
    if (username === ADMIN_USERNAME && password === ADMIN_PASSWORD) {
        const token = jwt.sign({ username }, JWT_SECRET, { expiresIn: '1d' });
        res.cookie(AUTH_TOKEN_NAME, token, { httpOnly: true, secure: process.env.NODE_ENV === 'production', maxAge: 86400000 }); // 1 day
        res.redirect('/admin.html');
    } else {
        res.redirect('/login.html?error=1');
    }
});
app.get('/api/logout', (req, res) => {
    res.clearCookie(AUTH_TOKEN_NAME);
    res.redirect('/login.html');
});

app.get('/admin.html', requirePageAuth, (req, res) => {
    res.sendFile(path.join(__dirname, 'public', 'admin.html'));
});
app.get('/admin', requirePageAuth, (req, res) => {
    res.redirect('/admin.html');
});

app.get('/api/images', async (req, res) => {
    const images = await readDB(dbPath);
    const { category } = req.query;
    if (category && category !== 'all' && category !== 'random') {
        res.json(images.filter(img => img.category === category));
    } else if (category === 'random') {
        res.json(images.sort(() => 0.5 - Math.random()));
    } else {
        res.json(images);
    }
});

app.get('/api/categories', async (req, res) => {
    let allDefinedCategories = await readDB(categoriesPath);
    const images = await readDB(dbPath);
    const isUncategorizedUsed = images.some(img => img.category === UNCATEGORIZED);
    let categoriesToShow = allDefinedCategories.filter(cat => cat !== UNCATEGORIZED || isUncategorizedUsed);
    const uncategorized = categoriesToShow.find(c => c === UNCATEGORIZED);
    let otherCategories = categoriesToShow.filter(c => c !== UNCATEGORIZED);
    otherCategories.sort((a, b) => a.localeCompare(b, 'zh-CN'));
    let sortedCategories = uncategorized ? [uncategorized, ...otherCategories] : otherCategories;
    res.json(sortedCategories);
});

const apiAdminRouter = express.Router();
apiAdminRouter.use(requireApiAuth);

const storage = multer.diskStorage({ destination: (req, file, cb) => cb(null, uploadsDir), filename: (req, file, cb) => { const uniqueSuffix = uuidv4(); const extension = path.extname(file.originalname); cb(null, `${uniqueSuffix}${extension}`); } });
const upload = multer({ storage: storage });

apiAdminRouter.post('/upload', upload.single('image'), async (req, res) => {
    if (!req.file) return res.status(400).json({ message: '没有选择文件。' });
    const images = await readDB(dbPath);
    const newImage = { id: uuidv4(), src: `/uploads/${req.file.filename}`, category: req.body.category || UNCATEGORIZED, description: req.body.description || '无描述', filename: req.file.filename, size: req.file.size, uploadedAt: new Date().toISOString() };
    images.unshift(newImage);
    await writeDB(dbPath, images);
    res.status(200).json({ message: '上传成功' });
});

apiAdminRouter.delete('/images/:id', async (req, res) => {
    let images = await readDB(dbPath);
    const imageToDelete = images.find(img => img.id === req.params.id);
    if (!imageToDelete) return res.status(404).json({ message: '图片未找到' });
    const filePath = path.join(uploadsDir, imageToDelete.filename);
    try {
        await fs.access(filePath);
        await fs.unlink(filePath);
    } catch (error) {
        console.error(`删除文件失败: ${filePath}`, error);
    }
    const updatedImages = images.filter(img => img.id !== req.params.id);
    await writeDB(dbPath, updatedImages);
    res.json({ message: '删除成功' });
});

apiAdminRouter.put('/images/:id', async (req, res) => {
    let images = await readDB(dbPath);
    const { category, description, filename } = req.body;
    const imageIndex = images.findIndex(img => img.id === req.params.id);
    if (imageIndex === -1) return res.status(404).json({ message: '图片未找到' });
    const imageToUpdate = images[imageIndex];
    if (filename && filename !== imageToUpdate.filename) {
        let oldPath = path.join(uploadsDir, imageToUpdate.filename);
        let newPath = path.join(uploadsDir, filename);
        try {
            await fs.access(newPath);
            return res.status(400).json({ message: '新文件名已存在。' });
        } catch (error) {
            // New path does not exist, which is good.
            try {
                await fs.rename(oldPath, newPath);
                imageToUpdate.filename = filename;
                imageToUpdate.src = `/uploads/${filename}`;
            } catch (renameError) {
                console.error(`重命名文件失败: ${oldPath} -> ${newPath}`, renameError);
                return res.status(500).json({ message: '文件重命名失败。' });
            }
        }
    }
    imageToUpdate.category = category || imageToUpdate.category;
    imageToUpdate.description = description === undefined ? imageToUpdate.description : description;
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

apiAdminRouter.post('/categories/delete', async (req, res) => {
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
    if (!JWT_SECRET) {
        console.error(`${RED}错误: JWT_SECRET 未在 .env 文件中设置。这是一个严重的安全风险。${NC}`);
        console.error(`${YELLOW}请在 .env 文件中添加一行: JWT_SECRET=your_super_secret_random_string${NC}`);
        process.exit(1);
    }
    await initializeDirectories();
    app.listen(PORT, () => console.log(`服务器正在 http://localhost:${PORT} 运行`));
})();
EOF

    echo "--> 正在生成主画廊 public/index.html (无改动)..."
cat << 'EOF' > public/index.html
<!DOCTYPE html><html lang="zh-CN"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0"><title>图片画廊</title><meta name="description" content="一个展示精彩瞬间的瀑布流图片画廊。"><link rel="preconnect" href="https://fonts.googleapis.com"><link rel="preconnect" href="https://fonts.gstatic.com" crossorigin><link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;700&family=Noto+Sans+SC:wght@400;500;700&display=swap" rel="stylesheet"><script src="https://cdn.tailwindcss.com"></script><style>body { font-family: 'Inter', 'Noto Sans SC', sans-serif; background-color: #f0fdf4; color: #14532d; display: flex; flex-direction: column; min-height: 100vh; } body.lightbox-open { overflow: hidden; } .filter-btn { padding: 0.5rem 1rem; border-radius: 9999px; font-weight: 500; transition: all 0.2s ease; border: 1px solid transparent; cursor: pointer; } .filter-btn:hover { background-color: #dcfce7; } .filter-btn.active { background-color: #22c55e; color: white; border-color: #16a34a; } .grid-gallery { display: grid; grid-template-columns: repeat(auto-fill, minmax(180px, 1fr)); grid-auto-rows: 10px; gap: 1rem; } .grid-item { position: relative; border-radius: 0.5rem; overflow: hidden; background-color: #e4e4e7; box-shadow: 0 4px 6px -1px rgb(0 0 0 / 0.1), 0 2px 4px -2px rgb(0 0 0 / 0.1); opacity: 0; transform: translateY(20px); transition: opacity 0.5s ease-out, transform 0.5s ease-out, box-shadow 0.3s ease; } .grid-item-wide { grid-column: span 2; } @media (max-width: 400px) { .grid-item-wide { grid-column: span 1; } } .grid-item.is-visible { opacity: 1; transform: translateY(0); } .grid-item img { cursor: pointer; width: 100%; height: 100%; object-fit: cover; display: block; transition: transform 0.4s ease; } .grid-item:hover img { transform: scale(1.05); } .lightbox { position: fixed; top: 0; left: 0; width: 100%; height: 100%; background-color: rgba(0, 0, 0, 0.9); display: flex; justify-content: center; align-items: center; z-index: 1000; opacity: 0; visibility: hidden; transition: opacity 0.3s ease; } .lightbox.active { opacity: 1; visibility: visible; } .lightbox-image { max-width: 85%; max-height: 85%; display: block; object-fit: contain; } .lightbox-btn { position: absolute; top: 50%; transform: translateY(-50%); background-color: rgba(255,255,255,0.1); color: white; border: none; font-size: 2.5rem; cursor: pointer; padding: 0.5rem 1rem; border-radius: 0.5rem; transition: background-color 0.2s; } .lightbox-btn:hover { background-color: rgba(255,255,255,0.2); } .lb-prev { left: 1rem; } .lb-next { right: 1rem; } .lb-close { top: 1rem; right: 1rem; font-size: 2rem; } .lb-counter { position: absolute; top: 1.5rem; left: 50%; transform: translateX(-50%); color: white; font-size: 1rem; background-color: rgba(0,0,0,0.3); padding: 0.25rem 0.75rem; border-radius: 9999px; } .back-to-top { position: fixed; bottom: 2rem; right: 2rem; background-color: #22c55e; color: white; width: 3rem; height: 3rem; border-radius: 9999px; display: flex; align-items: center; justify-content: center; box-shadow: 0 4px 8px rgba(0,0,0,0.2); cursor: pointer; opacity: 0; visibility: hidden; transform: translateY(20px); transition: all 0.3s ease; } .back-to-top.visible { opacity: 1; visibility: visible; transform: translateY(0); } .lb-download { position: absolute; bottom: 1rem; right: 1rem; background-color: #22c55e; color: white; border: none; padding: 0.5rem 1rem; border-radius: 0.5rem; cursor: pointer; transition: background-color 0.2s; font-size: 1rem; } .lb-download:hover { background-color: #16a34a; } .header-sticky { padding-top: 1rem; padding-bottom: 1rem; background-color: rgba(240, 253, 244, 0); position: sticky; top: 0; z-index: 40; box-shadow: 0 4px 6px -1px rgb(0 0 0 / 0.1), 0 2px 4px -2px rgb(0 0 0 / 0.1); transition: padding 0.3s ease-in-out, background-color 0.3s ease-in-out; } .header-sticky h1 { opacity: 1; margin-bottom: 0.75rem; transition: opacity 0.3s ease-in-out, margin-bottom 0.3s ease-in-out; } .header-sticky.state-scrolled-partially { padding-top: 0.75rem; padding-bottom: 0.75rem; background-color: rgba(240, 253, 244, 0.8); backdrop-filter: blur(8px); } .header-sticky.state-scrolled-fully { padding-top: 0.5rem; padding-bottom: 0.5rem; background-color: rgba(240, 253, 244, 0.8); backdrop-filter: blur(8px); } .header-sticky.state-scrolled-fully h1 { opacity: 0; margin-bottom: 0; height: 0; overflow: hidden; pointer-events: none; } #filter-buttons { transition: none; margin-top: 0; } </style></head><body class="antialiased"><header class="text-center header-sticky"><h1 class="text-4xl md:text-5xl font-bold text-green-900 mb-4">图片画廊</h1><div id="filter-buttons" class="flex justify-center flex-wrap space-x-2"><button class="filter-btn active" data-filter="all">全部</button><button class="filter-btn" data-filter="random">随机</button></div></header><main class="container mx-auto px-6 py-8 md:py-10 flex-grow"><div id="gallery-container" class="max-w-7xl mx-auto grid-gallery"></div><div id="loader" class="text-center py-8 text-green-700 hidden">正在加载更多...</div></main><footer class="text-center py-8 mt-auto border-t border-green-200"><p class="text-green-700">© 2025 图片画廊</p></footer><div class="lightbox"><span class="lb-counter"></span><button class="lightbox-btn lb-close">&times;</button><button class="lightbox-btn lb-prev">&lsaquo;</button><img class="lightbox-image" alt=""><button class="lightbox-btn lb-next">&rsaquo;</button><button class="lb-download">下载</button></div><a class="back-to-top" title="返回顶部"><svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 19V5M5 12l7-7 7 7"/></svg></a><script> document.addEventListener('DOMContentLoaded', function () { const galleryContainer = document.getElementById('gallery-container'); const loader = document.getElementById('loader'); let currentFilter = 'all'; let filteredData = []; let itemsLoaded = 0; let isRendering = false; async function createFilterButtons() { try { const response = await fetch('/api/categories'); const categories = await response.json(); const container = document.getElementById('filter-buttons'); container.querySelectorAll('.dynamic-filter').forEach(btn => btn.remove()); categories.forEach(category => { const button = document.createElement('button'); button.className = 'filter-btn dynamic-filter'; button.dataset.filter = category; button.textContent = category; container.appendChild(button); }); addFilterButtonListeners(); } catch (error) { console.error('无法加载分类按钮:', error); } } function addFilterButtonListeners() { const filterButtons = document.querySelectorAll('.filter-btn'); filterButtons.forEach(button => { button.addEventListener('click', () => { if (isRendering) return; currentFilter = button.dataset.filter; filterButtons.forEach(btn => btn.classList.remove('active')); button.classList.add('active'); initializeGallery(); }); }); } async function initializeGallery() { galleryContainer.innerHTML = ''; itemsLoaded = 0; isRendering = false; loader.classList.remove('hidden'); loader.textContent = '正在加载...'; try { const response = await fetch(`/api/images?category=${currentFilter}`); const imageData = await response.json(); filteredData = imageData; if(filteredData.length === 0){ loader.textContent = '该分类下没有图片。'; } else { loader.textContent = '正在加载更多...'; renderItems(); } } catch (error) { console.error('获取图片数据失败:', error); loader.textContent = '加载失败，请刷新页面。'; } } function renderItems() { if (isRendering) return; if (itemsLoaded >= filteredData.length) { loader.classList.add('hidden'); return; } isRendering = true; loader.classList.remove('hidden'); const itemsToRender = filteredData.slice(itemsLoaded, itemsLoaded + (12)); itemsToRender.forEach((data) => { const item = document.createElement('div'); item.className = 'grid-item'; item.dataset.category = data.category; item.dataset.index = filteredData.findIndex(img => img.id === data.id); const img = document.createElement('img'); img.src = "data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7"; img.dataset.src = data.src;  img.alt = data.description; item.appendChild(img); galleryContainer.appendChild(item); imageObserver.observe(item); }); itemsLoaded += itemsToRender.length; if (itemsLoaded >= filteredData.length) { loader.classList.add('hidden'); } isRendering = false; } const imageObserver = new IntersectionObserver((entries, observer) => { entries.forEach(entry => { if (entry.isIntersecting) { const item = entry.target; const img = item.querySelector('img'); img.src = img.dataset.src; img.onload = () => { item.style.backgroundColor = 'transparent'; item.classList.add('is-visible'); resizeSingleGridItem(item); }; observer.unobserve(item); } }); }, { rootMargin: '0px 0px 200px 0px' }); function resizeSingleGridItem(item) { const img = item.querySelector('img'); if (!img || !img.complete || img.naturalHeight === 0) return; const rowHeight = 10; const rowGap = 16; const ratio = img.naturalWidth / img.naturalHeight; if (ratio > 1.2) { item.classList.add('grid-item-wide'); } else { item.classList.remove('grid-item-wide'); } const clientWidth = img.clientWidth; if (clientWidth > 0) { const scaledHeight = clientWidth / ratio; const rowSpan = Math.ceil((scaledHeight + rowGap) / (rowHeight + rowGap)); item.style.gridRowEnd = `span ${rowSpan}`; } } const lightbox = document.querySelector('.lightbox'); const backToTopBtn = document.querySelector('.back-to-top'); const lightboxImage = lightbox.querySelector('.lightbox-image'); const lbCounter = lightbox.querySelector('.lb-counter'); const lbPrev = lightbox.querySelector('.lb-prev'); const lbNext = lightbox.querySelector('.lb-next'); const lbClose = lightbox.querySelector('.lb-close'); const lbDownload = lightbox.querySelector('.lb-download'); let currentImageIndex = 0; let lastFocusedElement; galleryContainer.addEventListener('click', (e) => { const item = e.target.closest('.grid-item'); if (item) { lastFocusedElement = document.activeElement; currentImageIndex = parseInt(item.dataset.index); updateLightbox(); lightbox.classList.add('active'); document.body.classList.add('lightbox-open'); lbClose.focus(); } }); function updateLightbox() { const currentItem = filteredData[currentImageIndex]; if (!currentItem) return; lightboxImage.src = currentItem.src; lightboxImage.alt = currentItem.description; lbCounter.textContent = `${currentImageIndex + 1} / ${filteredData.length}`; } function showPrevImage() { currentImageIndex = (currentImageIndex - 1 + filteredData.length) % filteredData.length; updateLightbox(); } function showNextImage() { currentImageIndex = (currentImageIndex + 1) % filteredData.length; updateLightbox(); } function closeLightbox() { lightbox.classList.remove('active'); document.body.classList.remove('lightbox-open'); if (lastFocusedElement) { lastFocusedElement.focus(); } } lbPrev.addEventListener('click', showPrevImage); lbNext.addEventListener('click', showNextImage); lbClose.addEventListener('click', closeLightbox); lbDownload.addEventListener('click', () => { const currentItem = filteredData[currentImageIndex]; if (currentItem && currentItem.src) { const a = document.createElement('a'); a.href = currentItem.src; a.download = currentItem.src.split('/').pop(); document.body.appendChild(a); a.click(); document.body.removeChild(a); } }); lightbox.addEventListener('click', (e) => { if (e.target === lightbox) closeLightbox(); }); document.addEventListener('keydown', (e) => { if (!lightbox.classList.contains('active')) return; if (e.key === 'ArrowLeft') showPrevImage(); if (e.key === 'ArrowRight') showNextImage(); if (e.key === 'Escape') closeLightbox(); }); backToTopBtn.addEventListener('click', () => { window.scrollTo({ top: 0, behavior: 'smooth' }); }); window.addEventListener('resize', () => { galleryContainer.querySelectorAll('.grid-item.is-visible').forEach(resizeSingleGridItem); }); const header = document.querySelector('.header-sticky'); let ticking = false; function handleScroll() { const currentScrollY = window.scrollY; if (currentScrollY > 300) { backToTopBtn.classList.add('visible'); } else { backToTopBtn.classList.remove('visible'); } if (currentScrollY > 50) { header.classList.add('state-scrolled-fully'); header.classList.remove('state-scrolled-partially'); } else if (currentScrollY > 0) { header.classList.add('state-scrolled-partially'); header.classList.remove('state-scrolled-fully'); } else { header.classList.remove('state-scrolled-fully', 'state-scrolled-partially'); } if (window.innerHeight + window.scrollY >= document.body.offsetHeight - 500) { if (itemsLoaded < filteredData.length) { renderItems(); } } } window.addEventListener('scroll', () => { if (!ticking) { window.requestAnimationFrame(() => { handleScroll(); ticking = false; }); ticking = true; } }); async function init() { await createFilterButtons(); initializeGallery(); } init(); }); </script></body></html>
EOF

    echo "--> 正在生成后台登录页 public/login.html (无改动)..."
cat << 'EOF' > public/login.html
<!DOCTYPE html><html lang="zh-CN"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0"><title>后台登录 - 图片画廊</title><script src="https://cdn.tailwindcss.com"></script><style> body { background-color: #f0fdf4; } </style></head><body class="antialiased text-green-900"><div class="min-h-screen flex items-center justify-center"><div class="max-w-md w-full bg-white p-8 rounded-lg shadow-lg"><h1 class="text-3xl font-bold text-center text-green-900 mb-6">后台管理登录</h1><div id="error-message" class="hidden bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded relative mb-4" role="alert"><strong class="font-bold">登录失败！</strong><span class="block sm:inline">用户名或密码不正确。</span></div><form action="/api/login" method="POST"><div class="mb-4"><label for="username" class="block text-green-800 text-sm font-bold mb-2">用户名</label><input type="text" id="username" name="username" required class="shadow appearance-none border rounded w-full py-2 px-3 text-gray-700 leading-tight focus:outline-none focus:ring-2 focus:ring-green-500"></div><div class="mb-6"><label for="password" class="block text-green-800 text-sm font-bold mb-2">密码</label><input type="password" id="password" name="password" required class="shadow appearance-none border rounded w-full py-2 px-3 text-gray-700 mb-3 leading-tight focus:outline-none focus:ring-2 focus:ring-green-500"></div><div class="flex items-center justify-between"><button type="submit" class="w-full bg-green-600 hover:bg-green-700 text-white font-bold py-2 px-4 rounded-lg focus:outline-none focus:shadow-outline transition-colors"> 登 录 </button></div></form></div></div><script> const urlParams = new URLSearchParams(window.location.search); if (urlParams.has('error')) { document.getElementById('error-message').classList.remove('hidden'); } </script></body></html>
EOF

    echo "--> 正在生成后台管理页 public/admin.html (UX全面升级)..."
cat << 'EOF' > public/admin.html
<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>后台管理 - 图片画廊</title>
    <script src="https://cdn.tailwindcss.com"></script>
    <style>
        body { background-color: #f0fdf4; }
        .modal, .toast { display: none; }
        .modal.active { display: flex; }
        .category-item.active { background-color: #dcfce7; font-weight: bold; }
        .toast { position: fixed; top: 1.5rem; right: 1.5rem; z-index: 9999; transform: translateX(120%); transition: transform 0.3s ease-in-out; }
        .toast.show { transform: translateX(0); }
    </style>
</head>
<body class="antialiased text-green-900">
    <header class="bg-white shadow-md p-4 flex justify-between items-center sticky top-0 z-10">
        <h1 class="text-2xl font-bold text-green-900">内容管理系统</h1>
        <div><a href="/" target="_blank" class="text-green-600 hover:text-green-800 mr-4">查看前台</a><a href="/api/logout" class="bg-red-500 hover:bg-red-700 text-white font-bold py-2 px-4 rounded transition-colors">退出登录</a></div>
    </header>

    <main class="container mx-auto p-6 grid grid-cols-1 lg:grid-cols-3 gap-8">
        <div class="lg:col-span-1 space-y-8">
            <section class="bg-white p-6 rounded-lg shadow-md">
                <h2 class="text-xl font-semibold mb-4">上传新图片</h2>
                <form id="upload-form" class="space-y-4">
                    <div>
                        <label for="image" class="w-full flex flex-col items-center justify-center p-4 border-2 border-dashed border-gray-300 rounded-lg cursor-pointer hover:bg-gray-50">
                            <svg class="w-8 h-8 mb-2 text-gray-500" aria-hidden="true" xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 20 16"><path stroke="currentColor" stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M13 13h3a3 3 0 0 0 0-6h-.025A5.56 5.56 0 0 0 16 6.5 5.5 5.5 0 0 0 5.207 5.021C5.137 5.017 5.071 5 5 5a4 4 0 0 0 0 8h2.167M10 15V6m0 0L8 8m2-2 2 2"/></svg>
                            <p class="text-sm text-gray-500"><span class="font-semibold">点击选择文件</span> 或拖拽到此处</p>
                            <input id="image" name="image" type="file" class="hidden" required />
                        </label>
                         <div id="file-info-wrapper" class="mt-2 text-xs text-gray-500" style="display: none;">
                            <span id="file-name-info"></span> | <span id="file-size-info"></span>
                        </div>
                    </div>
                    <div><label for="category-select" class="block text-sm font-medium mb-1">图片分类</label><div class="flex items-center space-x-2"><select name="category" id="category-select" required class="w-full border rounded px-3 py-2 focus:outline-none focus:ring-2 focus:ring-green-500"></select><button type="button" id="add-category-btn" class="flex-shrink-0 bg-green-500 hover:bg-green-600 text-white font-bold w-9 h-9 rounded-full flex items-center justify-center text-xl" title="添加新分类">+</button></div></div>
                    <div><label for="description" class="block text-sm font-medium mb-1">图片描述</label><input type="text" name="description" id="description" placeholder="对图片的简短描述" class="w-full border rounded px-3 py-2 focus:outline-none focus:ring-2 focus:ring-green-500"></div>
                    <button type="submit" id="upload-btn" class="w-full bg-green-600 hover:bg-green-700 text-white font-bold py-2 px-4 rounded-lg transition-colors">上传图片</button>
                </form>
            </section>

            <section class="bg-white p-6 rounded-lg shadow-md">
                <h2 class="text-xl font-semibold mb-4">分类管理</h2>
                <div id="category-management-list" class="space-y-2"></div>
            </section>
        </div>
        <section class="bg-white p-6 rounded-lg shadow-md lg:col-span-2">
            <div class="flex justify-between items-center mb-4">
                <h2 class="text-xl font-semibold">已上传图片 <span id="image-list-title" class="text-base text-gray-500 font-normal"></span></h2>
                <button id="show-all-images-btn" class="hidden bg-gray-200 hover:bg-gray-300 text-sm py-1 px-3 rounded-full">显示全部</button>
            </div>
            <div id="image-list" class="grid grid-cols-2 sm:grid-cols-3 md:grid-cols-4 gap-4"></div>
        </section>
    </main>
    
    <div id="generic-modal" class="modal fixed inset-0 bg-black bg-opacity-50 items-center justify-center z-20"><div class="bg-white rounded-lg shadow-xl p-6 w-full max-w-sm"><h3 id="modal-title" class="text-lg font-bold mb-4"></h3><div id="modal-body" class="mb-4"></div><div id="modal-footer" class="flex justify-end space-x-2"></div></div></div>
    <div id="edit-image-modal" class="modal fixed inset-0 bg-black bg-opacity-50 items-center justify-center z-20"><div class="bg-white rounded-lg shadow-xl p-6 w-full max-w-md"><h3 class="text-lg font-bold mb-4">编辑图片信息</h3><form id="edit-image-form"><input type="hidden" id="edit-id"><div class="mb-4"><label for="edit-filename" class="block text-sm font-medium mb-1">文件名</label><input type="text" id="edit-filename" class="w-full border rounded px-3 py-2"></div><div class="mb-4"><label for="edit-category-select" class="block text-sm font-medium mb-1">分类</label><select id="edit-category-select" class="w-full border rounded px-3 py-2"></select></div><div class="mb-4"><label for="edit-description" class="block text-sm font-medium mb-1">描述</label><input type="text" id="edit-description" class="w-full border rounded px-3 py-2"></div><div class="mt-4 pt-4 border-t text-sm text-gray-600 space-y-2"><div><strong>文件大小:</strong> <span id="edit-info-size"></span></div><div><strong>上传日期:</strong> <span id="edit-info-date"></span></div></div><div class="flex justify-end space-x-2 mt-6"><button type="button" class="modal-cancel-btn bg-gray-300 hover:bg-gray-400 text-black py-2 px-4 rounded">取消</button><button type="submit" class="bg-green-600 hover:bg-green-700 text-white py-2 px-4 rounded">保存更改</button></div></form></div></div>

    <div id="toast" class="toast max-w-xs bg-gray-800 text-white text-sm rounded-lg shadow-lg p-3" role="alert"><div class="flex items-center"><div id="toast-icon" class="mr-2"></div><span id="toast-message"></span></div></div>

    <script>
    document.addEventListener('DOMContentLoaded', function() {
        const imageList = document.getElementById('image-list');
        const uploadForm = document.getElementById('upload-form');
        const uploadBtn = document.getElementById('upload-btn');
        const categorySelect = document.getElementById('category-select');
        const categoryManagementList = document.getElementById('category-management-list');
        const addCategoryBtn = document.getElementById('add-category-btn');
        const editImageModal = document.getElementById('edit-image-modal');
        const editImageForm = document.getElementById('edit-image-form');
        const editCategorySelect = document.getElementById('edit-category-select');
        const imageListTitle = document.getElementById('image-list-title');
        const showAllImagesBtn = document.getElementById('show-all-images-btn');
        const imageInput = document.getElementById('image');
        const fileInfoWrapper = document.getElementById('file-info-wrapper');
        const fileNameInfo = document.getElementById('file-name-info');
        const fileSizeInfo = document.getElementById('file-size-info');
        const editInfoSize = document.getElementById('edit-info-size');
        const editInfoDate = document.getElementById('edit-info-date');

        const apiRequest = async (url, options = {}) => {
            try {
                const response = await fetch(url, options);
                if (response.status === 401) {
                    showToast('登录状态已过期，请重新登录。', 'error');
                    setTimeout(() => window.location.href = '/login.html', 2000);
                    throw new Error('Unauthorized');
                }
                return response;
            } catch (error) {
                if (error.message !== 'Unauthorized') showToast('网络或服务器错误。', 'error');
                throw error;
            }
        };
        
        const formatBytes = (bytes, decimals = 2) => { if (!+bytes) return 'N/A'; const k = 1024; const dm = decimals < 0 ? 0 : decimals; const sizes = ["Bytes", "KB", "MB", "GB", "TB"]; const i = Math.floor(Math.log(bytes) / Math.log(k)); return `${parseFloat((bytes / Math.pow(k, i)).toFixed(dm))} ${sizes[i]}`; }
        const formatDate = (isoString) => { if (!isoString) return 'N/A'; return new Date(isoString).toLocaleString('zh-CN', { year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit' }); }

        const showToast = (message, type = 'success') => {
            const toast = document.getElementById('toast');
            const toastMessage = document.getElementById('toast-message');
            const toastIcon = document.getElementById('toast-icon');
            toastMessage.textContent = message;
            if (type === 'success') {
                toast.classList.remove('bg-red-600');
                toast.classList.add('bg-gray-800');
                toastIcon.innerHTML = `<svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M5 13l4 4L19 7"></path></svg>`;
            } else {
                toast.classList.remove('bg-gray-800');
                toast.classList.add('bg-red-600');
                toastIcon.innerHTML = `<svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 8v4m0 4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z"></path></svg>`;
            }
            toast.style.display = 'block';
            setTimeout(() => toast.classList.add('show'), 10);
            setTimeout(() => {
                toast.classList.remove('show');
                setTimeout(() => toast.style.display = 'none', 300);
            }, 3000);
        };

        const modal = document.getElementById('generic-modal');
        const showModal = (title, bodyHtml, footerHtml) => {
            document.getElementById('modal-title').textContent = title;
            document.getElementById('modal-body').innerHTML = bodyHtml;
            document.getElementById('modal-footer').innerHTML = footerHtml;
            modal.classList.add('active');
        };
        const hideModal = () => modal.classList.remove('active');
        modal.addEventListener('click', e => { if (e.target === modal || e.target.closest('.modal-cancel-btn')) hideModal(); });

        async function refreshAll(newCat) {
            await loadAndPopulateCategories(newCat);
            await loadAndDisplayCategoriesForManagement();
            await loadImages('all');
            document.querySelectorAll('.category-item').forEach(el => el.classList.remove('active'));
        }

        async function loadAndPopulateCategories(selectedCategory = null) {
            try {
                const response = await apiRequest('/api/categories');
                if (!response.ok) throw new Error('网络响应不佳');
                const categories = await response.json();
                [categorySelect, editCategorySelect].forEach(select => {
                    select.innerHTML = '';
                    if (categories.length === 0 || (categories.length === 1 && categories[0] === '未分类')) {
                        const defaultOption = new Option('请先添加一个分类', '');
                        defaultOption.disabled = true;
                        select.add(defaultOption);
                    } else {
                        categories.forEach(cat => {
                            const option = new Option(cat, cat);
                            if (selectedCategory && cat === selectedCategory) option.selected = true;
                            select.add(option.cloneNode(true));
                        });
                    }
                });
            } catch (error) { if (error.message !== 'Unauthorized') console.error('无法加载分类列表:', error); }
        }

        async function loadAndDisplayCategoriesForManagement() {
            try {
                const response = await apiRequest('/api/categories');
                const categories = await response.json();
                categoryManagementList.innerHTML = '';
                categories.forEach(cat => {
                    const isUncategorized = cat === '未分类';
                    const item = document.createElement('div');
                    item.className = 'category-item flex items-center justify-between p-2 rounded cursor-pointer hover:bg-gray-50';
                    item.dataset.categoryName = cat;
                    item.innerHTML = `<span class="category-name flex-grow ${isUncategorized ? 'text-gray-500' : ''}">${cat}</span>` + (isUncategorized ? '' : `<div class="space-x-2 flex-shrink-0"><button data-name="${cat}" class="rename-cat-btn text-blue-500 hover:text-blue-700 text-sm">重命名</button><button data-name="${cat}" class="delete-cat-btn text-red-500 hover:red-700 text-sm">删除</button></div>`);
                    categoryManagementList.appendChild(item);
                });
            } catch (error) { if (error.message !== 'Unauthorized') console.error('无法加载分类管理列表:', error); }
        }

        async function loadImages(category = 'all') {
            try {
                imageListTitle.textContent = category === 'all' ? '' : `(${category})`;
                showAllImagesBtn.classList.toggle('hidden', category === 'all');
                const response = await apiRequest(`/api/images?category=${category}`);
                const images = await response.json();
                imageList.innerHTML = '';
                images.forEach(image => {
                    const div = document.createElement('div');
                    div.className = 'relative group';
                    div.innerHTML = `<img src="${image.src}" alt="${image.description}" class="w-full h-32 object-cover rounded-md"><div class="absolute inset-0 bg-black bg-opacity-50 p-2 flex flex-col justify-end text-white opacity-0 group-hover:opacity-100 transition-opacity rounded-md text-xs"><p class="font-bold truncate w-full">${image.filename}</p><p>${image.category}</p><p class="text-gray-300">${formatBytes(image.size)}</p><p class="text-gray-300">${formatDate(image.uploadedAt)}</p><div class="absolute top-1 right-1 space-x-1"><button data-id='${JSON.stringify(image)}' class="edit-btn text-white bg-blue-500 hover:bg-blue-600 w-6 h-6 rounded-full flex items-center justify-center text-sm font-bold">改</button><button data-id="${image.id}" class="delete-btn text-white bg-red-500 hover:bg-red-600 w-6 h-6 rounded-full flex items-center justify-center text-sm font-bold">删</button></div></div>`;
                    imageList.appendChild(div);
                });
            } catch(error) { if (error.message !== 'Unauthorized') console.error('无法加载图片:', error); }
        }

        imageInput.addEventListener('change', (e) => {
            const file = e.target.files[0];
            if(file) {
                fileNameInfo.textContent = file.name;
                fileSizeInfo.textContent = formatBytes(file.size);
                fileInfoWrapper.style.display = 'block';
            } else {
                fileInfoWrapper.style.display = 'none';
            }
        });

        uploadForm.addEventListener('submit', async (e) => {
            e.preventDefault();
            const formData = new FormData(uploadForm);
            if (!formData.get('category')) { showToast('请选择或创建一个分类。', 'error'); return; }
            uploadBtn.textContent = '正在上传...';
            uploadBtn.disabled = true;
            try {
                const response = await apiRequest('/api/admin/upload', { method: 'POST', body: formData });
                if (response.ok) {
                    showToast('上传成功！');
                    uploadForm.reset();
                    fileInfoWrapper.style.display = 'none';
                    await refreshAll();
                } else {
                    const error = await response.json();
                    showToast('上传失败: ' + (error.message || '未知错误'), 'error');
                }
            } catch (error) { /* Handled by apiRequest */ }
            finally { uploadBtn.textContent = '上传图片'; uploadBtn.disabled = false; }
        });
        
        addCategoryBtn.addEventListener('click', () => {
            showModal(
                '添加新分类',
                '<form id="modal-form"><input type="text" id="modal-input" placeholder="输入新分类的名称" required class="w-full border rounded px-3 py-2"></form>',
                '<button type="button" class="modal-cancel-btn bg-gray-300 hover:bg-gray-400 text-black py-2 px-4 rounded">取消</button><button type="submit" form="modal-form" class="bg-green-600 hover:bg-green-700 text-white py-2 px-4 rounded">保存</button>'
            );
            const form = document.getElementById('modal-form');
            form.addEventListener('submit', async (e) => {
                e.preventDefault();
                const newName = document.getElementById('modal-input').value.trim();
                if (!newName) return;
                try {
                    const response = await apiRequest('/api/admin/categories', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ name: newName }) });
                    const result = await response.json();
                    if (response.ok) {
                        hideModal();
                        showToast('分类创建成功');
                        await refreshAll(result.category);
                    } else {
                        showToast('添加失败: ' + result.message, 'error');
                    }
                } catch (error) { /* Handled by apiRequest */ }
            });
        });
        
        categoryManagementList.addEventListener('click', async (e) => {
            const target = e.target;
            const categoryItem = target.closest('.category-item');
            if (!categoryItem) return;
            const categoryName = categoryItem.dataset.categoryName;
            
            if (target.classList.contains('delete-cat-btn')) {
                showModal(
                    '确认删除',
                    `<p>确定要删除分类 "<strong>${categoryName}</strong>" 吗？<br>所有属于此分类的图片将被移至 "未分类"。</p>`,
                    '<button type="button" class="modal-cancel-btn bg-gray-300 hover:bg-gray-400 text-black py-2 px-4 rounded">取消</button><button id="confirm-delete" class="bg-red-600 hover:bg-red-700 text-white py-2 px-4 rounded">确认删除</button>'
                );
                document.getElementById('confirm-delete').onclick = async () => {
                    try {
                        const response = await apiRequest('/api/admin/categories/delete', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ name: categoryName }) });
                        if (response.ok) {
                            hideModal();
                            showToast(`分类 '${categoryName}' 已删除。`);
                            await refreshAll();
                        } else {
                            const err = await response.json();
                            showToast(`删除失败: ${err.message}`, 'error');
                        }
                    } catch (error) { /* Handled by apiRequest */ }
                };
            } else if (target.classList.contains('rename-cat-btn')) {
                showModal(
                    '重命名分类',
                    `<form id="modal-form"><input type="text" id="modal-input" value="${categoryName}" required class="w-full border rounded px-3 py-2"></form>`,
                    '<button type="button" class="modal-cancel-btn bg-gray-300 hover:bg-gray-400 text-black py-2 px-4 rounded">取消</button><button type="submit" form="modal-form" class="bg-green-600 hover:bg-green-700 text-white py-2 px-4 rounded">保存</button>'
                );
                document.getElementById('modal-form').addEventListener('submit', async (e) => {
                    e.preventDefault();
                    const newName = document.getElementById('modal-input').value.trim();
                    if (newName && newName !== categoryName) {
                        try {
                            const response = await apiRequest('/api/admin/categories', { method: 'PUT', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ oldName: categoryName, newName: newName }) });
                            if (response.ok) {
                                hideModal();
                                showToast('重命名成功');
                                await refreshAll();
                            } else {
                                const err = await response.json();
                                showToast(`重命名失败: ${err.message}`, 'error');
                            }
                        } catch (error) { /* Handled by apiRequest */ }
                    } else {
                        hideModal();
                    }
                });
            } else {
                document.querySelectorAll('.category-item').forEach(el => el.classList.remove('active'));
                categoryItem.classList.add('active');
                await loadImages(categoryName);
            }
        });

        showAllImagesBtn.addEventListener('click', async () => {
            document.querySelectorAll('.category-item').forEach(el => el.classList.remove('active'));
            await loadImages('all');
        });

        imageList.addEventListener('click', async (e) => {
            const target = e.target;
            const editBtn = target.closest('.edit-btn');
            const deleteBtn = target.closest('.delete-btn');

            if (deleteBtn) {
                const imageId = deleteBtn.dataset.id;
                showModal(
                    '确认删除',
                    '<p>确定要永久删除这张图片吗？此操作无法撤销。</p>',
                    '<button type="button" class="modal-cancel-btn bg-gray-300 hover:bg-gray-400 text-black py-2 px-4 rounded">取消</button><button id="confirm-delete-img" class="bg-red-600 hover:bg-red-700 text-white py-2 px-4 rounded">确认删除</button>'
                );
                document.getElementById('confirm-delete-img').onclick = async () => {
                    try {
                        const response = await apiRequest(`/api/admin/images/${imageId}`, { method: 'DELETE' });
                        if (response.ok) {
                            hideModal();
                            showToast('图片已删除');
                            loadImages(document.querySelector('.category-item.active')?.dataset.categoryName || 'all');
                        } else {
                            showToast('删除失败。', 'error');
                        }
                    } catch (error) { /* Handled by apiRequest */ }
                };
            } else if (editBtn) {
                const imageToEdit = JSON.parse(editBtn.dataset.id);
                document.getElementById('edit-id').value = imageToEdit.id;
                document.getElementById('edit-filename').value = imageToEdit.filename;
                document.getElementById('edit-description').value = imageToEdit.description || '';
                editInfoSize.textContent = formatBytes(imageToEdit.size);
                editInfoDate.textContent = formatDate(imageToEdit.uploadedAt);
                await loadAndPopulateCategories();
                editCategorySelect.value = imageToEdit.category;
                editImageModal.classList.add('active');
            }
        });
        
        document.querySelectorAll('.modal-cancel-btn').forEach(btn => btn.addEventListener('click', () => btn.closest('.modal').classList.remove('active')));
        editImageForm.addEventListener('submit', async (e) => {
            e.preventDefault();
            const id = document.getElementById('edit-id').value;
            const body = JSON.stringify({ filename: document.getElementById('edit-filename').value, category: editCategorySelect.value, description: document.getElementById('edit-description').value });
            try {
                const response = await apiRequest(`/api/admin/images/${id}`, { method: 'PUT', headers: { 'Content-Type': 'application/json' }, body: body });
                if (response.ok) {
                    editImageModal.classList.remove('active');
                    showToast('更新成功');
                    loadImages(document.querySelector('.category-item.active')?.dataset.categoryName || 'all');
                } else {
                    const result = await response.json();
                    showToast('更新失败: ' + result.message, 'error');
                }
            } catch (error) { /* Handled by apiRequest */ }
        });

        refreshAll();
    });
    </script>
</body>
</html>
EOF

    echo -e "${GREEN}--- 所有项目文件已成功生成在 ${INSTALL_DIR} ---${NC}"
}

# --- 管理菜单功能 ---
display_access_info() {
    cd "${INSTALL_DIR}" || return
    local SERVER_IP
    SERVER_IP=$(hostname -I | awk '{print $1}')
    if [ -f ".env" ]; then
        # Source .env to get variables, handle potential errors
        set -o allexport; source .env; set +o allexport
        echo -e "${YELLOW}======================================================${NC}"
        echo -e "${YELLOW}           应用已就绪！请使用以下信息访问           ${NC}"
        echo -e "${YELLOW}======================================================${NC}"
        echo -e "前台画廊地址: ${GREEN}http://${SERVER_IP}:${PORT}${NC}"
        echo -e "后台管理地址: ${GREEN}http://${SERVER_IP}:${PORT}/admin${NC}"
        echo -e "后台登录用户: ${BLUE}${ADMIN_USERNAME}${NC}"
        echo -e "后台登录密码: ${BLUE}(您设置的密码)${NC}"
        echo -e "${YELLOW}======================================================${NC}"
    fi
}

install_app() {
    echo -e "${GREEN}--- 1. 开始安装应用 ---${NC}"
    echo "--> 正在检查系统环境..."
    if ! command -v node > /dev/null || ! command -v npm > /dev/null || ! command -v pm2 > /dev/null; then
        echo -e "${RED}错误: 核心依赖缺失!${NC}"
        echo -e "${YELLOW}请先手动安装 Node.js, npm 和 pm2.${NC}"
        echo "您可以尝试运行以下命令:"
        echo "  curl -sL https://deb.nodesource.com/setup_18.x | sudo -E bash -"
        echo "  sudo apt-get install -y nodejs"
        echo "  sudo npm install -g pm2"
        return 1
    else
        echo -e "${GREEN}--> Node.js, npm, pm2 环境已存在。${NC}"
    fi

    generate_files
    
    echo -e "${YELLOW}--- 安全设置向导 ---${NC}"
    read -p "请输入新的后台管理员用户名 [默认为 admin]: " new_username
    new_username=${new_username:-admin}
    
    local new_password
    while true; do
        read -s -p "请输入新的后台管理员密码 (必须填写): " new_password
        echo
        read -s -p "请再次输入密码以确认: " new_password_confirm
        echo
        if [ "$new_password" == "$new_password_confirm" ] && [ -n "$new_password" ]; then
            break
        else
            echo -e "${RED}密码不匹配或为空，请重试。${NC}"
        fi
    done

    # Generate a random JWT_SECRET
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

    echo "--> 正在安装项目依赖 (npm install)..."
    npm install
    echo -e "${GREEN}--- 安装完成！正在自动启动应用... ---${NC}"
    start_app
    display_access_info
}

start_app() {
    cd "${INSTALL_DIR}" || exit
    echo -e "${GREEN}--- 正在使用 PM2 启动应用... ---${NC}"
    if [ ! -f ".env" ]; then
        echo -e "${RED}错误: .env 文件不存在。请先运行安装程序 (选项1)。${NC}"
        return
    fi
    pm2 start server.js --name "$APP_NAME"
    pm2 startup
    pm2 save
    echo -e "${GREEN}--- 应用已启动！---${NC}"
}

manage_credentials() {
    cd "${INSTALL_DIR}" || exit
    echo -e "${YELLOW}--- 修改后台用户名和密码 ---${NC}"
    if [ ! -f ".env" ]; then
        echo -e "${RED}错误: .env 文件不存在。请先安装应用。${NC}"
        return
    fi
    
    local CURRENT_USER
    CURRENT_USER=$(grep 'ADMIN_USERNAME=' .env | cut -d '=' -f2)
    echo "当前用户名: ${CURRENT_USER}"
    read -p "请输入新的用户名 (留空则不修改): " new_username
    
    local new_password
    read -s -p "请输入新的密码 (留空则不修改): " new_password
    echo
    
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

    echo -e "${YELLOW}正在重启应用以使新凭据生效...${NC}"
    restart_app
}

stop_app() {
    echo -e "${YELLOW}--- 停止应用... ---${NC}"
    pm2 stop "$APP_NAME"
    echo -e "${GREEN}--- 应用已停止！---${NC}"
}

restart_app() {
    echo -e "${GREEN}--- 重启应用... ---${NC}"
    pm2 restart "$APP_NAME"
    echo -e "${GREEN}--- 应用已重启！---${NC}"
}

view_logs() {
    echo -e "${YELLOW}--- 显示应用日志 (按 Ctrl+C 退出)... ---${NC}"
    pm2 logs "$APP_NAME"
}

uninstall_app() {
    echo -e "${RED}--- 警告：这将从PM2中移除应用并删除整个项目文件夹！ ---${NC}"
    read -p "你确定要继续吗？ (y/n): " confirm
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        echo "--> 正在从 PM2 中删除应用..."
        pm2 delete "$APP_NAME"
        pm2 save --force
        echo "--> 正在删除项目文件夹 ${INSTALL_DIR}..."
        rm -rf "${INSTALL_DIR}"
        echo -e "${GREEN}应用已彻底卸载。${NC}"
    else
        echo "操作已取消。"
    fi
}

show_menu() {
    clear
    echo -e "${YELLOW}======================================================${NC}"
    echo -e "${YELLOW}     图片画廊 - 一体化部署与管理脚本 (v7.3)     ${NC}"
    echo -e "${YELLOW}======================================================${NC}"
    echo -e " 应用名称: ${GREEN}${APP_NAME}${NC}"
    echo -e " 安装路径: ${GREEN}${INSTALL_DIR}${NC}"
    if [ -d "${INSTALL_DIR}" ] && [ -f "${INSTALL_DIR}/.env" ]; then
        local SERVER_IP
        SERVER_IP=$(hostname -I | awk '{print $1}')
        local PORT
        PORT=$(grep 'PORT=' "${INSTALL_DIR}/.env" | cut -d '=' -f2)
        echo -e " 访问网址: ${GREEN}http://${SERVER_IP}:${PORT}${NC}"
    else
        echo -e " 访问网址: ${RED}(应用尚未安装)${NC}"
    fi
    echo -e "${YELLOW}------------------------------------------------------${NC}"
    echo " 1. 安装或修复应用 (首次使用)"
    echo " 2. 启动应用"
    echo " 3. 停止应用"
    echo " 4. 重启应用"
    echo " 5. 查看实时日志"
    echo " 6. 修改后台用户名和密码"
    echo " 7. 彻底卸载应用"
    echo " 0. 退出"
    echo -e "${YELLOW}------------------------------------------------------${NC}"
    read -p "请输入你的选择 [0-7]: " choice
    case $choice in
        1) install_app ;;
        2) start_app; display_access_info ;;
        3) stop_app ;;
        4) restart_app ;;
        5) view_logs ;;
        6) manage_credentials ;;
        7) uninstall_app ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效输入...${NC}" ;;
    esac
    read -p "按任意键返回主菜单..."
}

# --- 脚本主入口 ---
while true; do
    show_menu
done
