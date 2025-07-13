太棒了！这是一个非常明智的决定，拥有自己的VPS意味着您对项目拥有完全的控制权，这是成为一名全栈开发者的绝佳起点。

我们将分步完成这个激动人心的升级。我将为您提供每一步所需的全部代码和命令，并解释其作用。

-----

### **总体规划**

我们的项目现在将由两部分组成，它们会存在于您VPS上的同一个项目文件夹中：

1.  **后端 (Backend)**：一个名为 `server.js` 的Node.js程序。它将扮演“图书管理员”的角色，负责处理图片上传、保存，并提供图片列表。
2.  **前端 (Frontend)**：一个名为 `public` 的文件夹，里面存放着我们已经非常熟悉的 `index.html` 以及其他可能的文件（如CSS、客户端JavaScript等）。

### **第一步：环境准备 - 登录并设置您的VPS**

首先，我们需要登录到您的VPS并安装Node.js运行环境。

1.  **通过SSH登录您的VPS**
    打开您电脑的终端（Terminal）或命令提示符（Command Prompt），使用以下命令登录。请将 `your_username` 替换为您的VPS用户名，将 `your_vps_ip_address` 替换为您VPS的IP地址。

    ```bash
    ssh your_username@your_vps_ip_address
    ```

    然后输入您的VPS密码。

2.  **安装Node.js和npm**
    登录成功后，我们需要安装Node.js。npm（Node包管理器）会随Node.js一同被安装。大多数现代Linux发行版（如Ubuntu/Debian）可以使用以下命令：

    ```bash
    sudo apt update
    sudo apt install nodejs npm -y
    ```

    安装完成后，您可以通过以下命令检查是否成功安装，如果能看到版本号，则说明安装成功：

    ```bash
    node -v
    npm -v
    ```

3.  **创建项目文件夹**
    让我们为我们的画廊项目创建一个文件夹，并进入该文件夹。

    ```bash
    mkdir photo-gallery
    cd photo-gallery
    ```

### **第二步：创建后端 - `server.js`**

后端需要处理文件上传，我们需要两个核心的Node.js库：`express` 用于快速搭建Web服务器，`multer` 用于轻松处理文件上传。

1.  **初始化项目并安装依赖库**
    在 `photo-gallery` 文件夹内，执行以下命令：

    ```bash
    npm init -y
    npm install express multer
    ```

    这会创建一个 `package.json` 文件来管理您的项目，并安装我们需要的两个库。

2.  **创建后端代码文件**
    现在，我们来创建后端的核心文件 `server.js` 和存放图片的文件夹。

    ```bash
    touch server.js
    mkdir -p public/uploads
    ```

      * `server.js` 是我们的服务器主程序。
      * `public` 文件夹将存放所有前端文件（如 `index.html`）。
      * `uploads` 文件夹位于 `public` 内部，用于存放所有用户上传的图片，这样前端才能直接访问到它们。

3.  **编写 `server.js` 代码**
    使用一个文本编辑器（如 `nano` 或 `vim`）打开 `server.js`：

    ```bash
    nano server.js
    ```

    然后，将以下所有代码**完整地复制**并粘贴进去：

    ```javascript
    // server.js

    const express = require('express');
    const multer = require('multer');
    const fs = require('fs');
    const path = require('path');

    const app = express();
    const PORT = 3000; // 您可以根据需要更改端口号

    // --- 中间件设置 ---
    // 告诉Express我们的前端文件在 'public' 文件夹中
    app.use(express.static('public'));
    // 允许Express解析JSON格式的请求体（为未来功能准备）
    app.use(express.json());

    // --- Multer 文件上传配置 ---
    const storage = multer.diskStorage({
        destination: function (req, file, cb) {
            cb(null, 'public/uploads/'); // 设置图片存储路径
        },
        filename: function (req, file, cb) {
            // 设置文件名，防止重名：原始名 + 时间戳 + 扩展名
            cb(null, file.fieldname + '-' + Date.now() + path.extname(file.originalname));
        }
    });

    const upload = multer({ storage: storage });

    // --- API 接口定义 ---

    // 接口1: 获取所有已上传的图片列表
    app.get('/api/images', (req, res) => {
        const uploadDir = path.join(__dirname, 'public/uploads');
        
        fs.readdir(uploadDir, (err, files) => {
            if (err) {
                console.error("无法读取uploads文件夹:", err);
                return res.status(500).json({ error: '无法获取图片列表。' });
            }
            // 过滤掉非图片文件，并按修改时间倒序排列（最新的在前面）
            const images = files
                .filter(file => /\.(jpg|jpeg|png|gif)$/i.test(file))
                .map(file => ({
                    src: `uploads/${file}`, // 返回前端可访问的相对路径
                    mtime: fs.statSync(path.join(uploadDir, file)).mtime.getTime()
                }))
                .sort((a, b) => b.mtime - a.mtime)
                .map(file => ({ src: file.src, category: '未分类' })); // 暂时给所有图片一个默认分类

            res.json(images);
        });
    });

    // 接口2: 处理图片上传
    // 'galleryImage' 必须和前端上传表单里的字段名一致
    app.post('/api/upload', upload.single('galleryImage'), (req, res) => {
        if (!req.file) {
            return res.status(400).json({ error: '没有文件被上传。' });
        }
        console.log('文件已上传:', req.file.path);
        // 成功上传后，返回新文件的信息
        res.status(201).json({ 
            message: '文件上传成功！',
            file: {
                src: `uploads/${req.file.filename}`,
                category: '未分类'
            }
        });
    });

    // --- 启动服务器 ---
    app.listen(PORT, () => {
        console.log(`服务器已启动，正在监听端口 http://localhost:${PORT}`);
    });
    ```

    **按 `Ctrl + X`，然后按 `Y`，最后按 `Enter` 保存并退出 `nano` 编辑器。**

### **第三步：改造前端 - `index.html`**

现在，我们需要把 `index.html` 放入 `public` 文件夹，并修改它的JavaScript，让它从后端获取数据并具备上传功能。

1.  **创建并编辑 `index.html`**

    ```bash
    nano public/index.html
    ```

    将以下**全新的、已完全改造好**的HTML和JavaScript代码**完整地复制**进去：

    ```html
    <!DOCTYPE html>
    <html lang="zh-CN">
    <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <title>我的动态图片画廊</title>
        <script src="https://cdn.tailwindcss.com"></script>
        <style>
            body { font-family: 'Inter', 'Noto Sans SC', sans-serif; background-color: #f0fdf4; color: #14532d; display: flex; flex-direction: column; min-height: 100vh; }
            /* ... 其他所有CSS样式和之前一样，为简洁省略，您可以从之前版本复制过来 ... */
            .upload-form { background: white; padding: 1.5rem; border-radius: 0.5rem; box-shadow: 0 4px 6px -1px rgb(0 0 0 / 0.1); margin-bottom: 2rem; }
            .upload-form input[type="file"] { border: 1px solid #ddd; padding: 0.5rem; border-radius: 0.25rem; }
            .upload-form button { background-color: #22c55e; color: white; padding: 0.5rem 1rem; border-radius: 0.25rem; transition: background-color 0.2s; }
            .upload-form button:hover { background-color: #16a34a; }
            .grid-gallery { display: grid; grid-template-columns: repeat(auto-fill, minmax(180px, 1fr)); grid-auto-rows: 10px; gap: 1rem; }
            .grid-item { position: relative; border-radius: 0.5rem; overflow: hidden; background-color: #e4e4e7; opacity: 0; transform: translateY(20px); transition: all 0.5s ease; }
            .grid-item-wide { grid-column: span 2; }
            @media (max-width: 400px) { .grid-item-wide { grid-column: span 1; } }
            .grid-item.is-visible { opacity: 1; transform: translateY(0); }
            .grid-item img { cursor: pointer; width: 100%; height: 100%; object-fit: cover; display: block; }
        </style>
    </head>
    <body class="antialiased">

        <header class="text-center py-8 md:py-12 bg-white/80 backdrop-blur-md shadow-sm sticky top-0 z-40">
            <h1 class="text-4xl md:text-5xl font-bold text-green-900 mb-4">我的动态图片画廊</h1>
        </header>

        <main class="container mx-auto px-6 py-8 md:py-10 flex-grow">
            <div class="max-w-xl mx-auto">
                <form id="upload-form" class="upload-form">
                    <h2 class="text-xl font-semibold mb-4 text-green-800">上传新图片</h2>
                    <input type="file" name="galleryImage" id="galleryImage" required>
                    <button type="submit">上传</button>
                    <p id="upload-status" class="mt-2 text-sm"></p>
                </form>
            </div>

            <div id="gallery-container" class="max-w-7xl mx-auto grid-gallery mt-8">
                </div>
        </main>
        
        <footer class="text-center py-8 mt-auto border-t border-green-200">
            <p class="text-green-700">© 2025 图片画廊</p>
        </footer>

        <script>
        document.addEventListener('DOMContentLoaded', function () {
            const galleryContainer = document.getElementById('gallery-container');
            const uploadForm = document.getElementById('upload-form');
            const uploadStatus = document.getElementById('upload-status');
            let allImageData = []; // 用于存放从后端获取的所有图片数据

            /**
             * 从后端API获取图片列表并渲染
             */
            async function fetchAndRenderImages() {
                try {
                    const response = await fetch('/api/images');
                    if (!response.ok) throw new Error('网络响应错误');
                    allImageData = await response.json();
                    
                    galleryContainer.innerHTML = ''; // 清空现有画廊
                    allImageData.forEach((data, index) => {
                        renderSingleItem(data, index);
                    });
                } catch (error) {
                    console.error('获取图片失败:', error);
                    galleryContainer.innerHTML = '<p>无法加载图片，请稍后重试。</p>';
                }
            }

            /**
             * 渲染单个图片项到页面
             */
            function renderSingleItem(data, index, isPrepended = false) {
                const item = document.createElement('div');
                item.className = 'grid-item';
                item.dataset.index = index;
                
                const img = document.createElement('img');
                img.src = data.src;
                
                img.onload = () => {
                    resizeSingleGridItem(item);
                    setTimeout(() => item.classList.add('is-visible'), 10);
                };
                img.onerror = () => item.remove();
                
                item.appendChild(img);

                if (isPrepended) {
                    galleryContainer.prepend(item);
                } else {
                    galleryContainer.appendChild(item);
                }
            }

            /**
             * 处理上传表单提交
             */
            uploadForm.addEventListener('submit', async function(e) {
                e.preventDefault();
                const formData = new FormData(this);
                const fileInput = document.getElementById('galleryImage');

                if (!fileInput.files[0]) {
                    uploadStatus.textContent = '请选择一个文件。';
                    return;
                }
                
                uploadStatus.textContent = '正在上传...';

                try {
                    const response = await fetch('/api/upload', {
                        method: 'POST',
                        body: formData
                    });

                    const result = await response.json();

                    if (!response.ok) {
                        throw new Error(result.error || '上传失败');
                    }

                    uploadStatus.textContent = result.message;
                    // 上传成功后，在画廊最前面动态添加新图片
                    allImageData.unshift(result.file);
                    renderSingleItem(result.file, 0, true);
                    // 重新计算所有项目的索引
                    reindexItems();

                } catch (error) {
                    console.error('上传出错:', error);
                    uploadStatus.textContent = `错误: ${error.message}`;
                } finally {
                    this.reset(); // 清空表单
                }
            });

            function reindexItems() {
                document.querySelectorAll('.grid-item').forEach((item, index) => {
                    item.dataset.index = index;
                });
            }

            function resizeSingleGridItem(item) {
                // ... 此处的布局计算函数和之前版本一样 ...
                const img = item.querySelector('img');
                if (!img || !img.complete || img.naturalHeight === 0) return;
                const rowHeight = 10; const rowGap = 16;
                const ratio = img.naturalWidth / img.naturalHeight;
                if (ratio > 1.2) { item.classList.add('grid-item-wide'); } else { item.classList.remove('grid-item-wide'); }
                const clientWidth = img.clientWidth;
                if (clientWidth > 0) { const scaledHeight = clientWidth / ratio; const rowSpan = Math.ceil((scaledHeight + rowGap) / (rowHeight + rowGap)); item.style.gridRowEnd = `span ${rowSpan}`; }
            }

            // 页面加载时，自动从后端获取图片
            fetchAndRenderImages();
        });
        </script>
    </body>
    </html>
    ```

    **同样按 `Ctrl + X`，然后按 `Y`，最后按 `Enter` 保存并退出。**

### **第四步：启动您的应用！**

现在，所有的代码和文件结构都已就位。您的 `photo-gallery` 文件夹看起来是这样的：

```
/photo-gallery
├── node_modules/
├── public/
│   ├── uploads/  (空文件夹)
│   └── index.html
├── package.json
├── package-lock.json
└── server.js
```

在 `photo-gallery` 文件夹的根目录下，执行以下命令来启动您的服务器：

```bash
node server.js
```

如果一切顺利，您会看到输出 “服务器已启动，正在监听端口 http://localhost:3000”。

### **最后一步：访问您的画廊**

现在，打开您本地电脑的浏览器，在地址栏输入：
`http://your_vps_ip_address:3000`

您应该能看到您的画廊页面了！并且，页面上会出现一个上传表单。尝试上传一张图片，它会立刻出现在画廊的最顶端！您上传的所有文件，都会被保存在VPS的 `/photo-gallery/public/uploads/` 文件夹中。

恭喜您！您已经成功地将您的静态画廊升级为了一个功能完备的全栈Web应用！这是一个巨大的进步。我们后续还可以继续在这个基础上进行优化，比如为图片增加分类功能等。
