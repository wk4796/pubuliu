#!/bin/bash

# =================================================================
#      图片画廊 专业版 - 一体化部署与管理脚本
#
#   说明: 此脚本包含了所有项目文件。运行安装选项后，
#         它会自动创建 server.js, package.json, HTML 文件等。
# =================================================================

# 定义颜色
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 应用在PM2中的名称
APP_NAME="image-gallery"
# 项目安装目录
INSTALL_DIR=$(pwd)/image-gallery-app

# --- 文件生成函数 ---
# 这个函数的核心作用是创建项目所需的所有文件和目录
generate_files() {
    echo -e "${YELLOW}--> 正在创建项目目录结构: ${INSTALL_DIR}${NC}"
    mkdir -p "${INSTALL_DIR}/public/uploads"
    mkdir -p "${INSTALL_DIR}/data"
    cd "${INSTALL_DIR}" || exit

    echo "--> 正在生成 package.json..."
cat << 'EOF' > package.json
{
  "name": "image-gallery-pro",
  "version": "1.0.0",
  "description": "A full-stack image gallery application.",
  "main": "server.js",
  "scripts": {
    "start": "node server.js"
  },
  "dependencies": {
    "body-parser": "^1.19.0",
    "cookie-parser": "^1.4.6",
    "dotenv": "^16.0.0",
    "express": "^4.17.1",
    "multer": "^1.4.4",
    "uuid": "^8.3.2"
  }
}
EOF

    echo "--> 正在生成 server.js..."
cat << 'EOF' > server.js
// 引入所需模块
const express = require('express');
const multer = require('multer');
const bodyParser = require('body-parser');
const path = require('path');
const fs = require('fs');
const { v4: uuidv4 } = require('uuid');
const cookieParser = require('cookie-parser');
require('dotenv').config(); // 加载 .env 文件中的环境变量

// 初始化 Express 应用
const app = express();
const PORT = process.env.PORT || 3000;
const ADMIN_USERNAME = process.env.ADMIN_USERNAME || 'admin';
const ADMIN_PASSWORD = process.env.ADMIN_PASSWORD || 'password';
const AUTH_TOKEN = 'auth_token'; // 用于 Cookie 的名称

// --- 数据文件路径 ---
const dbPath = path.join(__dirname, 'data', 'images.json');
const uploadsDir = path.join(__dirname, 'public', 'uploads');

// 确保数据目录和上传目录存在
if (!fs.existsSync(path.join(__dirname, 'data'))) fs.mkdirSync(path.join(__dirname, 'data'));
if (!fs.existsSync(uploadsDir)) fs.mkdirSync(uploadsDir);

// --- 中间件设置 ---
app.use(bodyParser.json());
app.use(bodyParser.urlencoded({ extended: true }));
app.use(cookieParser());
app.use(express.static(path.join(__dirname, 'public'))); // 托管 public 目录下的静态文件

// --- 图片上传设置 (使用 Multer) ---
const storage = multer.diskStorage({
    destination: (req, file, cb) => {
        cb(null, uploadsDir); // 设置上传文件的存储目录
    },
    filename: (req, file, cb) => {
        // 使用 uuid 生成唯一文件名，防止重名
        const uniqueSuffix = uuidv4();
        const extension = path.extname(file.originalname);
        cb(null, `${uniqueSuffix}${extension}`);
    }
});
const upload = multer({ storage: storage });

// --- 工具函数：读取和写入数据库文件 ---
const readDB = () => {
    if (!fs.existsSync(dbPath)) return [];
    try {
        const data = fs.readFileSync(dbPath);
        return JSON.parse(data);
    } catch (error) {
        return []; // 如果文件为空或损坏，返回空数组
    }
};

const writeDB = (data) => {
    fs.writeFileSync(dbPath, JSON.stringify(data, null, 2));
};

// --- 认证中间件 ---
const requireAuth = (req, res, next) => {
    if (req.cookies[AUTH_TOKEN] === ADMIN_PASSWORD) {
        next(); // 如果 cookie 验证成功，继续
    } else {
        res.redirect('/login.html'); // 否则，重定向到登录页
    }
};

// --- API 路由 ---

app.post('/api/login', (req, res) => {
    const { username, password } = req.body;
    if (username === ADMIN_USERNAME && password === ADMIN_PASSWORD) {
        res.cookie(AUTH_TOKEN, ADMIN_PASSWORD, { httpOnly: true, maxAge: 3600000 * 24 }); // 24小时有效
        res.redirect('/admin.html');
    } else {
        res.redirect('/login.html?error=1');
    }
});

app.get('/api/logout', (req, res) => {
    res.clearCookie(AUTH_TOKEN);
    res.redirect('/login.html');
});

app.get('/api/images', (req, res) => {
    const images = readDB();
    const { category } = req.query;
    if (category && category !== 'all' && category !== 'random') {
        res.json(images.filter(img => img.category === category));
    } else if (category === 'random') {
        res.json(images.sort(() => 0.5 - Math.random()));
    }
    else {
        res.json(images);
    }
});

app.post('/api/upload', requireAuth, upload.single('image'), (req, res) => {
    if (!req.file) {
        return res.status(400).send('没有选择文件。');
    }
    const images = readDB();
    const newImage = {
        id: uuidv4(),
        src: `/uploads/${req.file.filename}`,
        category: req.body.category || '未分类',
        description: req.body.description || '无描述',
        filename: req.file.filename
    };
    images.unshift(newImage);
    writeDB(images);
    res.redirect('/admin.html');
});

app.delete('/api/images/:id', requireAuth, (req, res) => {
    let images = readDB();
    const imageToDelete = images.find(img => img.id === req.params.id);
    if (!imageToDelete) {
        return res.status(404).json({ message: '图片未找到' });
    }
    const filePath = path.join(uploadsDir, imageToDelete.filename);
    if (fs.existsSync(filePath)) {
        fs.unlinkSync(filePath);
    }
    const updatedImages = images.filter(img => img.id !== req.params.id);
    writeDB(updatedImages);
    res.json({ message: '删除成功' });
});

app.put('/api/images/:id', requireAuth, (req, res) => {
    let images = readDB();
    const { category, description, filename } = req.body;
    const imageIndex = images.findIndex(img => img.id === req.params.id);

    if (imageIndex === -1) {
        return res.status(404).json({ message: '图片未找到' });
    }

    const imageToUpdate = images[imageIndex];
    let oldPath = path.join(uploadsDir, imageToUpdate.filename);

    imageToUpdate.category = category || imageToUpdate.category;
    imageToUpdate.description = description || imageToUpdate.description;

    if (filename && filename !== imageToUpdate.filename) {
        let newPath = path.join(uploadsDir, filename);
        if (fs.existsSync(newPath)) {
            return res.status(400).json({ message: '新文件名已存在，请使用其他名称。' });
        }
        fs.renameSync(oldPath, newPath);
        imageToUpdate.filename = filename;
        imageToUpdate.src = `/uploads/${filename}`;
    }

    images[imageIndex] = imageToUpdate;
    writeDB(images);
    res.json({ message: '更新成功', image: imageToUpdate });
});

// --- 受保护的后台页面 ---
app.get('/admin', requireAuth, (req, res) => {
    res.sendFile(path.join(__dirname, 'public', 'admin.html'));
});
app.get('/admin.html', requireAuth, (req, res) => {
    res.sendFile(path.join(__dirname, 'public', 'admin.html'));
});

// --- 启动服务器 ---
app.listen(PORT, () => {
    console.log(`服务器正在 http://localhost:${PORT} 运行`);
});
EOF

    echo "--> 正在生成 public/index.html..."
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
        body { font-family: 'Inter', 'Noto Sans SC', sans-serif; background-color: #f0fdf4; color: #14532d; display: flex; flex-direction: column; min-height: 100vh; }
        body.lightbox-open { overflow: hidden; }
        .filter-btn { padding: 0.5rem 1rem; border-radius: 9999px; font-weight: 500; transition: all 0.2s ease; border: 1px solid transparent; cursor: pointer; }
        .filter-btn:hover { background-color: #dcfce7; }
        .filter-btn.active { background-color: #22c55e; color: white; border-color: #16a34a; }
        .grid-gallery { display: grid; grid-template-columns: repeat(auto-fill, minmax(180px, 1fr)); grid-auto-rows: 10px; gap: 1rem; }
        .grid-item { position: relative; border-radius: 0.5rem; overflow: hidden; background-color: #e4e4e7; box-shadow: 0 4px 6px -1px rgb(0 0 0 / 0.1), 0 2px 4px -2px rgb(0 0 0 / 0.1); opacity: 0; transform: translateY(20px); transition: opacity 0.5s ease-out, transform 0.5s ease-out, box-shadow 0.3s ease; }
        .grid-item-wide { grid-column: span 2; }
        @media (max-width: 400px) { .grid-item-wide { grid-column: span 1; } }
        .grid-item.is-visible { opacity: 1; transform: translateY(0); }
        .grid-item img { cursor: pointer; width: 100%; height: 100%; object-fit: cover; display: block; transition: transform 0.4s ease; }
        .grid-item:hover img { transform: scale(1.05); }
        .lightbox { position: fixed; top: 0; left: 0; width: 100%; height: 100%; background-color: rgba(0, 0, 0, 0.9); display: flex; justify-content: center; align-items: center; z-index: 1000; opacity: 0; visibility: hidden; transition: opacity 0.3s ease; }
        .lightbox.active { opacity: 1; visibility: visible; }
        .lightbox-image { max-width: 85%; max-height: 85%; display: block; object-fit: contain; }
        .lightbox-btn { position: absolute; top: 50%; transform: translateY(-50%); background-color: rgba(255,255,255,0.1); color: white; border: none; font-size: 2.5rem; cursor: pointer; padding: 0.5rem 1rem; border-radius: 0.5rem; transition: background-color 0.2s; }
        .lightbox-btn:hover { background-color: rgba(255,255,255,0.2); }
        .lb-prev { left: 1rem; }
        .lb-next { right: 1rem; }
        .lb-close { top: 1rem; right: 1rem; font-size: 2rem; }
        .lb-counter { position: absolute; top: 1.5rem; left: 50%; transform: translateX(-50%); color: white; font-size: 1rem; background-color: rgba(0,0,0,0.3); padding: 0.25rem 0.75rem; border-radius: 9999px; }
        .back-to-top { position: fixed; bottom: 2rem; right: 2rem; background-color: #22c55e; color: white; width: 3rem; height: 3rem; border-radius: 9999px; display: flex; align-items: center; justify-content: center; box-shadow: 0 4px 8px rgba(0,0,0,0.2); cursor: pointer; opacity: 0; visibility: hidden; transform: translateY(20px); transition: all 0.3s ease; }
        .back-to-top.visible { opacity: 1; visibility: visible; transform: translateY(0); }
        .lb-download { position: absolute; bottom: 1rem; right: 1rem; background-color: #22c55e; color: white; border: none; padding: 0.5rem 1rem; border-radius: 0.5rem; cursor: pointer; transition: background-color 0.2s; font-size: 1rem; }
        .lb-download:hover { background-color: #16a34a; }
        .header-sticky { padding-top: 1rem; padding-bottom: 1rem; background-color: rgba(240, 253, 244, 0); position: sticky; top: 0; z-index: 40; box-shadow: 0 4px 6px -1px rgb(0 0 0 / 0.1), 0 2px 4px -2px rgb(0 0 0 / 0.1); transition: padding 0.3s ease-in-out, background-color 0.3s ease-in-out; }
        .header-sticky h1 { opacity: 1; margin-bottom: 0.75rem; transition: opacity 0.3s ease-in-out, margin-bottom 0.3s ease-in-out; }
        .header-sticky.state-scrolled-partially { padding-top: 0.75rem; padding-bottom: 0.75rem; background-color: rgba(240, 253, 244, 0.8); backdrop-filter: blur(8px); }
        .header-sticky.state-scrolled-fully { padding-top: 0.5rem; padding-bottom: 0.5rem; background-color: rgba(240, 253, 244, 0.8); backdrop-filter: blur(8px); }
        .header-sticky.state-scrolled-fully h1 { opacity: 0; margin-bottom: 0; height: 0; overflow: hidden; pointer-events: none; }
        #filter-buttons { transition: none; margin-top: 0; }
    </style>
</head>
<body class="antialiased">
    <header class="text-center header-sticky">
        <h1 class="text-4xl md:text-5xl font-bold text-green-900 mb-4">图片画廊</h1>
        <div id="filter-buttons" class="flex justify-center space-x-2">
            <button class="filter-btn active" data-filter="all">全部</button>
            <button class="filter-btn" data-filter="random">随机</button>
            <button class="filter-btn" data-filter="二次元">二次元</button>
            <button class="filter-btn" data-filter="风景">风景</button>
        </div>
    </header>
    <main class="container mx-auto px-6 py-8 md:py-10 flex-grow">
        <div id="gallery-container" class="max-w-7xl mx-auto grid-gallery"></div>
        <div id="loader" class="text-center py-8 text-green-700 hidden">正在加载更多...</div>
    </main>
    <footer class="text-center py-8 mt-auto border-t border-green-200">
        <p class="text-green-700">© 2025 图片画廊</p>
    </footer>
    <div class="lightbox">
        <span class="lb-counter"></span>
        <button class="lightbox-btn lb-close">&times;</button>
        <button class="lightbox-btn lb-prev">&lsaquo;</button>
        <img class="lightbox-image" alt="">
        <button class="lightbox-btn lb-next">&rsaquo;</button>
        <button class="lb-download">下载</button> 
    </div>
    <a class="back-to-top" title="返回顶部">
        <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 19V5M5 12l7-7 7 7"/></svg>
    </a>
    <script>
    document.addEventListener('DOMContentLoaded', function () {
        let imageData = [];
        const galleryContainer = document.getElementById('gallery-container');
        const loader = document.getElementById('loader');
        const itemsPerLoad = 12;
        let currentFilter = 'all';
        let filteredData = [];
        let itemsLoaded = 0;
        let isRendering = false;
        let lastFocusedElement;

        function renderItems() {
            if (isRendering) return;
            if (itemsLoaded >= filteredData.length) {
                loader.classList.add('hidden');
                return;
            }
            isRendering = true;
            loader.classList.remove('hidden');
            const itemsToRender = filteredData.slice(itemsLoaded, itemsLoaded + itemsPerLoad);
            itemsToRender.forEach((data, index) => {
                const item = document.createElement('div');
                item.className = 'grid-item';
                item.dataset.category = data.category;
                item.dataset.index = filteredData.findIndex(img => img.id === data.id);
                const img = document.createElement('img');
                img.src = "data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7";
                img.dataset.src = data.src; 
                img.alt = data.description;
                img.onerror = () => {
                    console.error('图片加载失败:', img.dataset.src);
                    item.remove();
                };
                item.appendChild(img);
                galleryContainer.appendChild(item);
                imageObserver.observe(item);
            });
            itemsLoaded += itemsToRender.length;
            if (itemsLoaded >= filteredData.length) {
                loader.classList.add('hidden');
            }
            isRendering = false;
        }
        
        const imageObserver = new IntersectionObserver((entries, observer) => {
            entries.forEach(entry => {
                if (entry.isIntersecting) {
                    const item = entry.target;
                    const img = item.querySelector('img');
                    img.src = img.dataset.src;
                    img.onload = () => {
                        item.style.backgroundColor = 'transparent';
                        item.classList.add('is-visible');
                        resizeSingleGridItem(item);
                    };
                    observer.unobserve(item);
                }
            });
        }, { rootMargin: '0px 0px 200px 0px' });

        function resizeSingleGridItem(item) {
            const img = item.querySelector('img');
            if (!img || !img.complete || img.naturalHeight === 0) return;
            const rowHeight = 10;
            const rowGap = 16;
            const ratio = img.naturalWidth / img.naturalHeight;
            if (ratio > 1.2) { item.classList.add('grid-item-wide'); } else { item.classList.remove('grid-item-wide'); }
            const clientWidth = img.clientWidth;
            if (clientWidth > 0) {
                const scaledHeight = clientWidth / ratio;
                const rowSpan = Math.ceil((scaledHeight + rowGap) / (rowHeight + rowGap));
                item.style.gridRowEnd = `span ${rowSpan}`;
            }
        }

        window.addEventListener('resize', () => {
            const items = galleryContainer.querySelectorAll('.grid-item.is-visible');
            items.forEach(resizeSingleGridItem);
        });
        
        const filterButtons = document.querySelectorAll('.filter-btn');
        filterButtons.forEach(button => {
            button.addEventListener('click', () => {
                if (isRendering) return;
                currentFilter = button.dataset.filter;
                filterButtons.forEach(btn => btn.classList.remove('active'));
                button.classList.add('active');
                initialize(); 
            });
        });

        const lightbox = document.querySelector('.lightbox'); 
        const backToTopBtn = document.querySelector('.back-to-top'); 
        const lightboxImage = lightbox.querySelector('.lightbox-image'); 
        const lbCounter = lightbox.querySelector('.lb-counter'); 
        const lbPrev = lightbox.querySelector('.lb-prev'); 
        const lbNext = lightbox.querySelector('.lb-next'); 
        const lbClose = lightbox.querySelector('.lb-close'); 
        const lbDownload = lightbox.querySelector('.lb-download'); 
        let currentImageIndex = 0; 

        galleryContainer.addEventListener('click', (e) => { 
            const item = e.target.closest('.grid-item'); 
            if (item) { 
                lastFocusedElement = document.activeElement; 
                currentImageIndex = parseInt(item.dataset.index); 
                updateLightbox(); 
                lightbox.classList.add('active'); 
                document.body.classList.add('lightbox-open'); 
                lbClose.focus();
            } 
        }); 

        function updateLightbox() { 
            const currentItem = filteredData[currentImageIndex]; 
            if (!currentItem) return; 
            lightboxImage.src = currentItem.src;
            lightboxImage.alt = currentItem.description;
            lbCounter.textContent = `${currentImageIndex + 1} / ${filteredData.length}`; 
        } 

        function showPrevImage() { 
            currentImageIndex = (currentImageIndex - 1 + filteredData.length) % filteredData.length; 
            updateLightbox(); 
        } 

        function showNextImage() { 
            currentImageIndex = (currentImageIndex + 1) % filteredData.length; 
            updateLightbox(); 
        } 

        function closeLightbox() { 
            lightbox.classList.remove('active'); 
            document.body.classList.remove('lightbox-open'); 
            if (lastFocusedElement) {
                lastFocusedElement.focus();
            }
        }
        
        lbPrev.addEventListener('click', showPrevImage); 
        lbNext.addEventListener('click', showNextImage); 
        lbClose.addEventListener('click', closeLightbox); 
        lbDownload.addEventListener('click', () => { 
            const currentItem = filteredData[currentImageIndex];
            if (currentItem && currentItem.src) {
                const a = document.createElement('a');
                a.href = currentItem.src;
                a.download = currentItem.src.split('/').pop();
                document.body.appendChild(a);
                a.click();
                document.body.removeChild(a);
            }
        });

        lightbox.addEventListener('click', (e) => { if (e.target === lightbox) closeLightbox(); }); 
        document.addEventListener('keydown', (e) => { 
            if (!lightbox.classList.contains('active')) return; 
            if (e.key === 'ArrowLeft') showPrevImage(); 
            if (e.key === 'ArrowRight') showNextImage(); 
            if (e.key === 'Escape') closeLightbox(); 
        }); 
        
        backToTopBtn.addEventListener('click', () => { window.scrollTo({ top: 0, behavior: 'smooth' }); });
        
        const header = document.querySelector('.header-sticky');
        let ticking = false;

        function handleScroll() {
            const currentScrollY = window.scrollY;
            if (currentScrollY > 300) { backToTopBtn.classList.add('visible'); } else { backToTopBtn.classList.remove('visible'); } 
            if (currentScrollY > 50) {
                header.classList.add('state-scrolled-fully');
                header.classList.remove('state-scrolled-partially');
            } else if (currentScrollY > 0) {
                header.classList.add('state-scrolled-partially');
                header.classList.remove('state-scrolled-fully');
            } else {
                header.classList.remove('state-scrolled-fully', 'state-scrolled-partially');
            }
            if (window.innerHeight + window.scrollY >= document.body.offsetHeight - 500) { 
                if (itemsLoaded < filteredData.length) { renderItems(); }
            } 
        }

        window.addEventListener('scroll', () => { 
            if (!ticking) {
                window.requestAnimationFrame(() => {
                    handleScroll();
                    ticking = false;
                });
                ticking = true;
            }
        }); 

        async function initialize() {
            galleryContainer.innerHTML = '';
            itemsLoaded = 0;
            isRendering = false;
            loader.classList.remove('hidden');
            loader.textContent = '正在加载...';
            
            try {
                const response = await fetch(`/api/images?category=${currentFilter}`);
                imageData = await response.json();
                filteredData = imageData;
                
                if(filteredData.length === 0){
                    loader.textContent = '该分类下没有图片。';
                } else {
                    loader.textContent = '正在加载更多...';
                    renderItems();
                }
            } catch (error) {
                console.error('获取图片数据失败:', error);
                loader.textContent = '加载失败，请刷新页面。';
            }
        }
        
        initialize();
    });
    </script>
</body>
</html>
EOF

    echo "--> 正在生成 public/login.html..."
cat << 'EOF' > public/login.html
<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>后台登录 - 图片画廊</title>
    <script src="https://cdn.tailwindcss.com"></script>
    <style> body { background-color: #f0fdf4; } </style>
</head>
<body class="antialiased text-green-900">
    <div class="min-h-screen flex items-center justify-center">
        <div class="max-w-md w-full bg-white p-8 rounded-lg shadow-lg">
            <h1 class="text-3xl font-bold text-center text-green-900 mb-6">后台管理登录</h1>
            <div id="error-message" class="hidden bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded relative mb-4" role="alert">
                <strong class="font-bold">登录失败！</strong>
                <span class="block sm:inline">用户名或密码不正确。</span>
            </div>
            <form action="/api/login" method="POST">
                <div class="mb-4">
                    <label for="username" class="block text-green-800 text-sm font-bold mb-2">用户名</label>
                    <input type="text" id="username" name="username" required class="shadow appearance-none border rounded w-full py-2 px-3 text-gray-700 leading-tight focus:outline-none focus:ring-2 focus:ring-green-500">
                </div>
                <div class="mb-6">
                    <label for="password" class="block text-green-800 text-sm font-bold mb-2">密码</label>
                    <input type="password" id="password" name="password" required class="shadow appearance-none border rounded w-full py-2 px-3 text-gray-700 mb-3 leading-tight focus:outline-none focus:ring-2 focus:ring-green-500">
                </div>
                <div class="flex items-center justify-between">
                    <button type="submit" class="w-full bg-green-600 hover:bg-green-700 text-white font-bold py-2 px-4 rounded-lg focus:outline-none focus:shadow-outline transition-colors">
                        登 录
                    </button>
                </div>
            </form>
        </div>
    </div>
    <script>
        const urlParams = new URLSearchParams(window.location.search);
        if (urlParams.has('error')) {
            document.getElementById('error-message').classList.remove('hidden');
        }
    </script>
</body>
</html>
EOF

    echo "--> 正在生成 public/admin.html..."
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
        .modal-bg { background-color: rgba(0,0,0,0.5); }
    </style>
</head>
<body class="antialiased text-green-900">
    <header class="bg-white shadow-md p-4 flex justify-between items-center">
        <h1 class="text-2xl font-bold text-green-900">图片内容管理</h1>
        <div>
            <a href="/" target="_blank" class="text-green-600 hover:text-green-800 mr-4">查看前台</a>
            <a href="/api/logout" class="bg-red-500 hover:bg-red-700 text-white font-bold py-2 px-4 rounded transition-colors">退出登录</a>
        </div>
    </header>
    <main class="container mx-auto p-6">
        <section class="bg-white p-6 rounded-lg shadow-md mb-8">
            <h2 class="text-xl font-semibold mb-4">上传新图片</h2>
            <form id="upload-form" action="/api/upload" method="POST" enctype="multipart/form-data">
                <div class="grid grid-cols-1 md:grid-cols-3 gap-4">
                    <div>
                        <label for="image" class="block text-sm font-medium mb-1">图片文件</label>
                        <input type="file" name="image" id="image" required class="w-full text-sm text-slate-500 file:mr-4 file:py-2 file:px-4 file:rounded-full file:border-0 file:text-sm file:font-semibold file:bg-green-50 file:text-green-700 hover:file:bg-green-100"/>
                    </div>
                    <div>
                        <label for="category" class="block text-sm font-medium mb-1">图片分类</label>
                        <input type="text" name="category" id="category" placeholder="例如: 风景, 二次元" required class="w-full border rounded px-3 py-2 focus:outline-none focus:ring-2 focus:ring-green-500">
                    </div>
                    <div>
                        <label for="description" class="block text-sm font-medium mb-1">图片描述</label>
                        <input type="text" name="description" id="description" placeholder="对图片的简短描述" class="w-full border rounded px-3 py-2 focus:outline-none focus:ring-2 focus:ring-green-500">
                    </div>
                </div>
                <button type="submit" class="mt-4 w-full bg-green-600 hover:bg-green-700 text-white font-bold py-2 px-4 rounded-lg transition-colors">上传图片</button>
            </form>
        </section>
        <section class="bg-white p-6 rounded-lg shadow-md">
            <h2 class="text-xl font-semibold mb-4">已上传图片</h2>
            <div id="image-list" class="grid grid-cols-2 md:grid-cols-4 lg:grid-cols-6 gap-4"></div>
        </section>
    </main>
    <div id="edit-modal" class="fixed inset-0 modal-bg items-center justify-center hidden">
        <div class="bg-white rounded-lg shadow-xl p-6 w-full max-w-md">
             <h3 class="text-lg font-bold mb-4">编辑图片信息</h3>
             <form id="edit-form">
                <input type="hidden" id="edit-id">
                <div class="mb-4">
                    <label for="edit-filename" class="block text-sm font-medium mb-1">文件名</label>
                    <input type="text" id="edit-filename" class="w-full border rounded px-3 py-2 focus:outline-none focus:ring-2 focus:ring-green-500">
                </div>
                <div class="mb-4">
                    <label for="edit-category" class="block text-sm font-medium mb-1">分类</label>
                    <input type="text" id="edit-category" class="w-full border rounded px-3 py-2 focus:outline-none focus:ring-2 focus:ring-green-500">
                </div>
                <div class="mb-4">
                    <label for="edit-description" class="block text-sm font-medium mb-1">描述</label>
                    <input type="text" id="edit-description" class="w-full border rounded px-3 py-2 focus:outline-none focus:ring-2 focus:ring-green-500">
                </div>
                <div class="flex justify-end space-x-2">
                    <button type="button" id="cancel-edit" class="bg-gray-300 hover:bg-gray-400 text-black py-2 px-4 rounded">取消</button>
                    <button type="submit" class="bg-green-600 hover:bg-green-700 text-white py-2 px-4 rounded">保存更改</button>
                </div>
            </form>
        </div>
    </div>
    <script>
    document.addEventListener('DOMContentLoaded', function() {
        const imageList = document.getElementById('image-list');
        const editModal = document.getElementById('edit-modal');
        const editForm = document.getElementById('edit-form');
        const cancelEditBtn = document.getElementById('cancel-edit');

        async function loadImages() {
            const response = await fetch('/api/images');
            const images = await response.json();
            imageList.innerHTML = '';
            images.forEach(image => {
                const div = document.createElement('div');
                div.className = 'relative group';
                div.innerHTML = `
                    <img src="${image.src}" alt="${image.description}" class="w-full h-32 object-cover rounded-md">
                    <div class="absolute inset-0 bg-black bg-opacity-50 flex flex-col items-center justify-center opacity-0 group-hover:opacity-100 transition-opacity rounded-md p-2">
                        <p class="text-white text-xs font-bold truncate w-full text-center">${image.filename}</p>
                        <p class="text-gray-300 text-xs">${image.category}</p>
                        <div class="mt-2">
                            <button data-id="${image.id}" class="edit-btn text-white text-xs bg-blue-500 hover:bg-blue-600 px-2 py-1 rounded">编辑</button>
                            <button data-id="${image.id}" class="delete-btn text-white text-xs bg-red-500 hover:bg-red-600 px-2 py-1 rounded">删除</button>
                        </div>
                    </div>
                `;
                imageList.appendChild(div);
            });
        }

        imageList.addEventListener('click', async (e) => {
            const target = e.target;
            const id = target.dataset.id;
            if (!id) return;

            if (target.classList.contains('delete-btn')) {
                if (confirm('确定要永久删除这张图片吗？')) {
                    const response = await fetch(`/api/images/${id}`, { method: 'DELETE' });
                    if (response.ok) { loadImages(); } else { alert('删除失败。'); }
                }
            }

            if (target.classList.contains('edit-btn')) {
                const response = await fetch('/api/images');
                const images = await response.json();
                const imageToEdit = images.find(img => img.id === id);
                if (imageToEdit) {
                    document.getElementById('edit-id').value = imageToEdit.id;
                    document.getElementById('edit-filename').value = imageToEdit.filename;
                    document.getElementById('edit-category').value = imageToEdit.category;
                    document.getElementById('edit-description').value = imageToEdit.description;
                    editModal.style.display = 'flex';
                }
            }
        });

        function closeEditModal() { editModal.style.display = 'none'; }
        cancelEditBtn.addEventListener('click', closeEditModal);
        
        editForm.addEventListener('submit', async (e) => {
            e.preventDefault();
            const id = document.getElementById('edit-id').value;
            const body = JSON.stringify({
                filename: document.getElementById('edit-filename').value,
                category: document.getElementById('edit-category').value,
                description: document.getElementById('edit-description').value
            });
            const response = await fetch(`/api/images/${id}`, {
                method: 'PUT',
                headers: { 'Content-Type': 'application/json' },
                body: body
            });
            const result = await response.json();
            if (response.ok) {
                closeEditModal();
                loadImages();
            } else {
                alert('更新失败: ' + result.message);
            }
        });

        loadImages();
    });
    </script>
</body>
</html>
EOF

    echo -e "${GREEN}--- 所有项目文件已成功生成在 ${INSTALL_DIR} ---${NC}"
}

# --- 管理菜单功能 ---
check_root() {
    if [ "$(id -u)" != "0" ]; then
        echo -e "${RED}错误: 此脚本需要以 root 权限运行。请使用 'sudo ./menu.sh'${NC}"
        exit 1
    fi
}

install_app() {
    echo -e "${GREEN}--- 1. 开始安装应用 ---${NC}"
    # 调用文件生成函数
    generate_files
    
    echo "--> 正在更新系统软件包列表..."
    apt-get update -y
    
    if ! command -v node > /dev/null; then
        echo "--> 正在安装 Node.js 和 npm..."
        apt-get install -y nodejs npm
    else
        echo -e "${YELLOW}--> Node.js 已安装。${NC}"
    fi
    
    if ! command -v pm2 > /dev/null; then
        echo "--> 正在全局安装 PM2..."
        npm install -g pm2
    else
        echo -e "${YELLOW}--> PM2 已安装。${NC}"
    fi
    
    echo "--> 正在安装项目依赖 (npm install)..."
    npm install
    
    echo -e "${GREEN}--- 安装完成！---${NC}"
    echo -e "${YELLOW}请使用菜单选项 '2' 来首次启动应用。${NC}"
}

start_app() {
    cd "${INSTALL_DIR}" || exit
    echo -e "${GREEN}--- 2. 正在使用 PM2 启动应用... ---${NC}"
    if [ ! -f ".env" ]; then
        echo -e "${YELLOW}警告: .env 文件不存在。将创建默认配置文件。${NC}"
        (
        echo "PORT=3000"
        echo "ADMIN_USERNAME=admin"
        echo "ADMIN_PASSWORD=password123"
        ) > .env
        echo "默认用户名: admin, 默认密码: password123. 请务必使用菜单中的选项 '6' 修改密码！"
    fi
    pm2 start server.js --name "$APP_NAME"
    pm2 startup
    pm2 save
    echo -e "${GREEN}--- 应用已启动！请访问 http://<你的IP>:3000 ---${NC}"
}

stop_app() {
    echo -e "${YELLOW}--- 3. 正在停止应用... ---${NC}"
    pm2 stop "$APP_NAME"
    echo -e "${GREEN}--- 应用已停止！---${NC}"
}

restart_app() {
    echo -e "${GREEN}--- 4. 正在重启应用... ---${NC}"
    pm2 restart "$APP_NAME"
    echo -e "${GREEN}--- 应用已重启！---${NC}"
}

view_logs() {
    echo -e "${YELLOW}--- 5. 正在显示应用日志 (按 Ctrl+C 退出)... ---${NC}"
    pm2 logs "$APP_NAME"
}

change_password() {
    cd "${INSTALL_DIR}" || exit
    echo -e "${YELLOW}--- 6. 修改管理员密码 ---${NC}"
    if [ ! -f ".env" ]; then
        echo -e "${RED}错误: .env 文件不存在。请先启动一次应用以自动创建。${NC}"
        return
    fi
    read -p "请输入新的管理员密码: " new_password
    if [ -z "$new_password" ]; then
        echo -e "${RED}密码不能为空！操作取消。${NC}"
        return
    fi
    sed -i "/^ADMIN_PASSWORD=/c\\ADMIN_PASSWORD=${new_password}" .env
    echo -e "${GREEN}密码已更新！正在重启应用以使新密码生效...${NC}"
    restart_app
}

uninstall_app() {
    echo -e "${RED}--- 7. 警告：这将从PM2中移除应用并删除整个项目文件夹！ ---${NC}"
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

# --- 主菜单 ---
show_menu() {
    clear
    echo -e "${YELLOW}======================================================${NC}"
    echo -e "${YELLOW}          图片画廊 - 一体化部署与管理脚本          ${NC}"
    echo -e "${YELLOW}======================================================${NC}"
    echo -e " 应用名称: ${GREEN}${APP_NAME}${NC}"
    echo -e " 安装路径: ${GREEN}${INSTALL_DIR}${NC}"
    echo -e "${YELLOW}------------------------------------------------------${NC}"
    echo " 1. 安装应用 (首次使用，将在此目录创建所有文件)"
    echo " 2. 启动应用"
    echo " 3. 停止应用"
    echo " 4. 重启应用"
    echo " 5. 查看实时日志"
    echo " 6. 修改后台密码"
    echo " 7. 彻底卸载应用 (删除PM2进程和所有文件)"
    echo " 0. 退出"
    echo -e "${YELLOW}------------------------------------------------------${NC}"
    read -p "请输入你的选择 [0-7]: " choice
    
    case $choice in
        1) check_root; install_app ;;
        2) start_app ;;
        3) stop_app ;;
        4) restart_app ;;
        5) view_logs ;;
        6) change_password ;;
        7) check_root; uninstall_app ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效输入，请输入 0 到 7 之间的数字。${NC}" ;;
    esac
    read -p "按任意键返回主菜单..."
}

# 脚本主循环
while true; do
    show_menu
done
