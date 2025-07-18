#!/bin/bash

# =================================================================
#   图片画廊 专业版 - 一体化部署与管理脚本 (v1.8.1)
#
#   作者: 编码助手 (经 Gemini Pro 优化)
#
#   v1.8.1 更新:
#   - 功能(迁移): 新增 JSON 到 SQLite 的自动数据迁移功能。当从旧版本升级时，
#                脚本会检测并提示用户执行一次性数据迁移，安全地保留所有历史数据。
#
#   v1.8.0 更新:
#   - 功能(核心): 数据库引擎从 JSON 文件升级为 SQLite。
#   - 功能(后台): 新增“清理图片缓存”功能。
#   - 优化(安装): 增强依赖自动安装。
# =================================================================

# --- 配置 ---
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color
PROMPT_Y="(${GREEN}y${NC}/${RED}n${NC})"

SCRIPT_VERSION="1.8.1"
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
  "version": "1.8.1",
  "description": "A high-performance, full-stack image gallery application with all features.",
  "main": "server.js",
  "scripts": {
    "start": "node server.js",
    "migrate": "node migrate-json-to-sqlite.js"
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
    "uuid": "^8.3.2",
    "better-sqlite3": "^9.4.3"
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
const Database = require('better-sqlite3');
require('dotenv').config();

const app = express();
const PORT = process.env.PORT || 3000;
const ADMIN_USERNAME = process.env.ADMIN_USERNAME || 'admin';
const ADMIN_PASSWORD = process.env.ADMIN_PASSWORD || 'password';
const JWT_SECRET = process.env.JWT_SECRET;
const AUTH_TOKEN_NAME = 'auth_token';
const UNCATEGORIZED = '未分类';

const dataDir = path.join(__dirname, 'data');
const dbPath = path.join(dataDir, 'gallery.db');
const uploadsDir = path.join(__dirname, 'public', 'uploads');
const cacheDir = path.join(__dirname, 'public', 'cache');

let db;

const initializeApp = async () => {
    try {
        await fs.mkdir(dataDir, { recursive: true });
        await fs.mkdir(uploadsDir, { recursive: true });
        await fs.mkdir(cacheDir, { recursive: true });
        
        db = new Database(dbPath);
        console.log('--> SQLite数据库连接成功。');

        db.exec(`
            CREATE TABLE IF NOT EXISTS images (
                id TEXT PRIMARY KEY,
                src TEXT NOT NULL,
                category TEXT DEFAULT '${UNCATEGORIZED}',
                description TEXT,
                originalFilename TEXT NOT NULL,
                filename TEXT NOT NULL,
                size INTEGER,
                uploadedAt TEXT NOT NULL,
                width INTEGER,
                height INTEGER,
                status TEXT DEFAULT 'active',
                deletedAt TEXT
            );
            CREATE TABLE IF NOT EXISTS categories (
                name TEXT PRIMARY KEY
            );
            CREATE TABLE IF NOT EXISTS config (
                key TEXT PRIMARY KEY,
                value TEXT
            );
            CREATE INDEX IF NOT EXISTS idx_images_category ON images(category);
            CREATE INDEX IF NOT EXISTS idx_images_status ON images(status);
        `);

        const uncategorizedExists = db.prepare('SELECT name FROM categories WHERE name = ?').get(UNCATEGORIZED);
        if (!uncategorizedExists) {
            db.prepare('INSERT INTO categories (name) VALUES (?)').run(UNCATEGORIZED);
        }
        console.log('--> 数据库表结构初始化/验证完成。');

    } catch (error) { 
        console.error('初始化失败:', error); 
        process.exit(1); 
    }
};

const getConfig = (key, defaultValue = null) => {
    const row = db.prepare('SELECT value FROM config WHERE key = ?').get(key);
    try {
      return row ? JSON.parse(row.value) : defaultValue;
    } catch {
      return defaultValue;
    }
};
const setConfig = (key, value) => {
    if (value === null || typeof value === 'undefined') {
        db.prepare('DELETE FROM config WHERE key = ?').run(key);
    } else {
        const jsonValue = JSON.stringify(value);
        db.prepare('INSERT OR REPLACE INTO config (key, value) VALUES (?, ?)')
          .run(key, jsonValue);
    }
};

app.use(bodyParser.json({ limit: '50mb' }));
app.use(bodyParser.urlencoded({ extended: true, limit: '50mb' }));
app.use(cookieParser());

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
    const tfaConfig = getConfig('tfa');
    res.json({ enabled: !!(tfaConfig && tfaConfig.secret) });
}));

app.post('/api/login', handleApiError(async (req, res) => {
    const { username, password, tfa_token } = req.body;
    if (username !== ADMIN_USERNAME || password !== ADMIN_PASSWORD) {
        return res.redirect('/login.html?error=1');
    }
    
    const tfaConfig = getConfig('tfa');
    if (tfaConfig && tfaConfig.secret) {
        if (!tfa_token) { return res.redirect('/login.html?error=2'); }
        const verified = speakeasy.totp.verify({
            secret: tfaConfig.secret,
            encoding: 'base32',
            token: tfa_token,
        });
        if (!verified) { return res.redirect('/login.html?error=3'); }
    }

    const token = jwt.sign({ username }, JWT_SECRET, { expiresIn: '1d' });
    res.cookie(AUTH_TOKEN_NAME, token, { httpOnly: true, secure: process.env.NODE_ENV === 'production', maxAge: 86400000 });
    res.redirect('/admin.html');
}));

app.get('/api/logout', (req, res) => { res.clearCookie(AUTH_TOKEN_NAME); res.redirect('/login.html'); });
app.get('/admin.html', requirePageAuth, (req, res) => res.sendFile(path.join(__dirname, 'public', 'admin.html')));
app.get('/admin', requirePageAuth, (req, res) => res.redirect('/admin.html'));

app.get('/api/images', handleApiError(async (req, res) => {
    const { category, search, page = 1, limit = 20, sort_by = 'date_desc' } = req.query;
    
    let whereClauses = ["status <> 'deleted'"];
    let params = [];
    
    if (search) {
        whereClauses.push("(originalFilename LIKE ? OR description LIKE ?)");
        params.push(`%${search}%`, `%${search}%`);
    }
    
    if (category && category !== 'all' && category !== 'random') {
        whereClauses.push("category = ?");
        params.push(category);
    }

    let orderBy = "ORDER BY uploadedAt DESC";
    switch (sort_by) {
        case 'date_asc': orderBy = "ORDER BY uploadedAt ASC"; break;
        case 'name_asc': orderBy = "ORDER BY originalFilename ASC"; break;
        case 'name_desc': orderBy = "ORDER BY originalFilename DESC"; break;
        case 'size_asc': orderBy = "ORDER BY size ASC"; break;
        case 'size_desc': orderBy = "ORDER BY size DESC"; break;
        case 'random': orderBy = "ORDER BY RANDOM()"; break;
    }
    if (category === 'random') { orderBy = "ORDER BY RANDOM()"; }

    const whereString = whereClauses.join(' AND ');
    const pageNum = parseInt(page);
    const limitNum = parseInt(limit);
    const offset = (pageNum - 1) * limitNum;

    const countResult = db.prepare(`SELECT COUNT(*) as count FROM images WHERE ${whereString}`).get(...params);
    const totalImages = countResult.count;
    
    const images = db.prepare(`SELECT * FROM images WHERE ${whereString} ${orderBy} LIMIT ? OFFSET ?`).all(...params, limitNum, offset);
    
    const totalPages = Math.ceil(totalImages / limitNum);

    res.json({
        images,
        page: pageNum,
        limit: limitNum,
        totalPages,
        totalImages,
        hasMore: pageNum < totalPages
    });
}));

app.get('/api/categories', handleApiError(async (req, res) => {
    const rows = db.prepare('SELECT name FROM categories ORDER BY CASE WHEN name = ? THEN 0 ELSE 1 END, name ASC').all(UNCATEGORIZED);
    res.json(rows.map(r => r.name));
}));

app.get('/api/public/categories', handleApiError(async (req, res) => {
    const rows = db.prepare(`
        SELECT DISTINCT T1.name FROM categories T1
        INNER JOIN images T2 ON T1.name = T2.category
        WHERE T2.status <> 'deleted'
        ORDER BY CASE WHEN T1.name = ? THEN 0 ELSE 1 END, T1.name ASC
    `).all(UNCATEGORIZED);
    res.json(rows.map(cat => cat.name));
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
    
    const placeholders = filenames.map(() => '?').join(',');
    const rows = db.prepare(`SELECT originalFilename FROM images WHERE status <> 'deleted' AND originalFilename IN (${placeholders})`).all(...filenames);
    const duplicates = rows.map(r => r.originalFilename);
    res.json({ duplicates });
}));

apiAdminRouter.post('/upload', upload.single('image'), handleApiError(async (req, res) => {
    if (!req.file) return res.status(400).json({ message: '没有选择文件。' });
    const metadata = await sharp(req.file.path).metadata();
    
    let originalFilename = req.file.originalname;
    if (req.body.rename === 'true') {
        const existing = db.prepare("SELECT 1 FROM images WHERE status <> 'deleted' AND originalFilename = ?").get(originalFilename);
        if (existing) {
            const ext = path.extname(originalFilename);
            const baseName = path.basename(originalFilename, ext);
            let counter = 1;
            do {
                originalFilename = `${baseName} (${counter})${ext}`;
                counter++;
            } while (db.prepare("SELECT 1 FROM images WHERE status <> 'deleted' AND originalFilename = ?").get(originalFilename));
        }
    }

    const newImage = { 
        id: uuidv4(), src: `/uploads/${req.file.filename}`, 
        category: req.body.category || UNCATEGORIZED, 
        description: req.body.description || '', 
        originalFilename: originalFilename,
        filename: req.file.filename, 
        size: req.file.size, uploadedAt: new Date().toISOString(),
        width: metadata.width, height: metadata.height,
        status: 'active', deletedAt: null
    };
    db.prepare('INSERT INTO images (id, src, category, description, originalFilename, filename, size, uploadedAt, width, height, status, deletedAt) VALUES (@id, @src, @category, @description, @originalFilename, @filename, @size, @uploadedAt, @width, @height, @status, @deletedAt)')
      .run(newImage);

    res.status(200).json({ message: '上传成功', image: newImage });
}));

apiAdminRouter.delete('/images/:id', handleApiError(async (req, res) => {
    const info = db.prepare("UPDATE images SET status = 'deleted', deletedAt = ? WHERE id = ?").run(new Date().toISOString(), req.params.id);
    if (info.changes === 0) return res.status(404).json({ message: '图片未找到' });
    res.json({ message: '图片已移至回收站' });
}));

apiAdminRouter.put('/images/:id', handleApiError(async (req, res) => {
    const { category, description, originalFilename } = req.body;
    const image = db.prepare("SELECT * FROM images WHERE id = ?").get(req.params.id);
    if (!image) return res.status(404).json({ message: '图片未找到' });

    if (originalFilename && originalFilename !== image.originalFilename) {
        const existing = db.prepare("SELECT 1 FROM images WHERE originalFilename = ? AND id <> ? AND status <> 'deleted'").get(originalFilename, req.params.id);
        if (existing) { return res.status(409).json({ message: '该文件名已存在。'}); }
        image.originalFilename = originalFilename;
    }
    image.category = category || image.category;
    image.description = description === undefined ? image.description : description;

    db.prepare("UPDATE images SET category = ?, description = ?, originalFilename = ? WHERE id = ?")
      .run(image.category, image.description, image.originalFilename, req.params.id);
    
    res.json({ message: '更新成功', image: db.prepare("SELECT * FROM images WHERE id = ?").get(req.params.id) });
}));

apiAdminRouter.post('/images/bulk-action', handleApiError(async (req, res) => {
    const { action, ids, payload } = req.body;
    if (!action || !Array.isArray(ids) || ids.length === 0) {
        return res.status(400).json({ message: '无效的请求' });
    }
    const placeholders = ids.map(() => '?').join(',');

    const bulkActionTransaction = db.transaction((action, ids, payload) => {
        const ph = ids.map(() => '?').join(',');
        switch (action) {
            case 'purge':
                const imagesToDelete = db.prepare(`SELECT filename FROM images WHERE id IN (${ph})`).all(...ids);
                for (const image of imagesToDelete) {
                    const filePath = path.join(uploadsDir, image.filename);
                    try { fs.unlinkSync(filePath); } 
                    catch (error) { console.error(`永久删除文件失败: ${filePath}`, error); }
                }
                db.prepare(`DELETE FROM images WHERE id IN (${ph})`).run(...ids);
                break;
            case 'delete':
                db.prepare(`UPDATE images SET status = 'deleted', deletedAt = ? WHERE id IN (${ph})`).run(new Date().toISOString(), ...ids);
                break;
            case 'restore':
                db.prepare(`UPDATE images SET status = 'active', deletedAt = NULL WHERE id IN (${ph})`).run(...ids);
                break;
            case 'recategorize':
                if (payload && payload.newCategory) {
                    db.prepare(`UPDATE images SET category = ? WHERE id IN (${ph})`).run(payload.newCategory, ...ids);
                }
                break;
            case 'edit_description':
                if (payload && typeof payload.newDescription !== 'undefined') {
                     db.prepare(`UPDATE images SET description = ? WHERE id IN (${ph})`).run(payload.newDescription, ...ids);
                }
                break;
        }
    });

    bulkActionTransaction(action, ids, payload);
    res.json({ message: `批量操作 '${action}' 已成功完成。` });
}));

apiAdminRouter.post('/categories', handleApiError(async (req, res) => {
    const { name } = req.body;
    if (!name || name.trim() === '') return res.status(400).json({ message: '分类名称不能为空。' });
    try {
        db.prepare('INSERT INTO categories (name) VALUES (?)').run(name);
        res.status(201).json({ message: '分类创建成功', category: name });
    } catch (error) {
        if (error.code === 'SQLITE_CONSTRAINT_PRIMARYKEY') {
            return res.status(409).json({ message: '该分类已存在。' });
        }
        throw error;
    }
}));

apiAdminRouter.delete('/categories', handleApiError(async (req, res) => {
    const { name } = req.body;
    if (!name || name === UNCATEGORIZED) return res.status(400).json({ message: '无效的分类或“未分类”无法删除。' });

    db.transaction(() => {
        const info = db.prepare('DELETE FROM categories WHERE name = ?').run(name);
        if (info.changes === 0) throw new Error('该分类不存在。');
        db.prepare('UPDATE images SET category = ? WHERE category = ?').run(UNCATEGORIZED, name);
    })();

    res.status(200).json({ message: `分类 '${name}' 已删除，相关图片已归入 '${UNCATEGORIZED}'。` });
}));

apiAdminRouter.put('/categories', handleApiError(async (req, res) => {
    const { oldName, newName } = req.body;
    if (!oldName || !newName || oldName === newName || oldName === UNCATEGORIZED) return res.status(400).json({ message: '无效的分类名称。' });
    
    try {
        db.transaction(() => {
            db.prepare('UPDATE categories SET name = ? WHERE name = ?').run(newName, oldName);
            db.prepare('UPDATE images SET category = ? WHERE category = ?').run(newName, oldName);
        })();
        res.status(200).json({ message: `分类 '${oldName}' 已重命名为 '${newName}'。` });
    } catch (error) {
        if (error.code === 'SQLITE_CONSTRAINT_PRIMARYKEY') {
             return res.status(409).json({ message: '新的分类名称已存在。' });
        }
        throw error;
    }
}));

apiAdminRouter.get('/recycle-bin', handleApiError(async (req, res) => {
    const { search, page = 1, limit = 12, sort_by = 'date_desc' } = req.query;
    let whereClauses = ["status = 'deleted'"];
    let params = [];
    if (search) {
        whereClauses.push("(originalFilename LIKE ? OR description LIKE ?)");
        params.push(`%${search}%`, `%${search}%`);
    }
    
    let orderBy = "ORDER BY deletedAt DESC";
    switch (sort_by) {
        case 'date_asc': orderBy = "ORDER BY deletedAt ASC"; break;
        case 'name_asc': orderBy = "ORDER BY originalFilename ASC"; break;
        case 'name_desc': orderBy = "ORDER BY originalFilename DESC"; break;
        case 'size_asc': orderBy = "ORDER BY size ASC"; break;
        case 'size_desc': orderBy = "ORDER BY size DESC"; break;
    }

    const whereString = whereClauses.join(' AND ');
    const pageNum = parseInt(page);
    const limitNum = parseInt(limit);
    const offset = (pageNum - 1) * limitNum;
    
    const countResult = db.prepare(`SELECT COUNT(*) as count FROM images WHERE ${whereString}`).get(...params);
    const totalImages = countResult.count;
    const images = db.prepare(`SELECT * FROM images WHERE ${whereString} ${orderBy} LIMIT ? OFFSET ?`).all(...params, limitNum, offset);
    
    res.json({ images, page: pageNum, totalPages: Math.ceil(totalImages / limitNum), totalImages });
}));

apiAdminRouter.post('/recycle-bin/:id/restore', handleApiError(async (req, res) => {
    const info = db.prepare("UPDATE images SET status = 'active', deletedAt = NULL WHERE id = ?").run(req.params.id);
    if(info.changes === 0) return res.status(404).json({ message: '图片未找到' });
    res.json({ message: '图片已成功恢复' });
}));

apiAdminRouter.delete('/recycle-bin/:id/purge', handleApiError(async (req, res) => {
    const imageToDelete = db.prepare("SELECT filename FROM images WHERE id = ? AND status = 'deleted'").get(req.params.id);
    if (!imageToDelete) return res.status(404).json({ message: '图片未找到' });

    const filePath = path.join(uploadsDir, imageToDelete.filename);
    try { await fs.unlink(filePath); } catch (error) { console.error(`删除文件失败: ${filePath}`, error); }
    
    db.prepare("DELETE FROM images WHERE id = ?").run(req.params.id);
    res.json({ message: '图片已永久删除' });
}));

apiAdminRouter.get('/maintenance/find-orphans', handleApiError(async (req, res) => {
    const allFiles = await fs.readdir(uploadsDir);
    const dbFilenames = new Set(db.prepare('SELECT filename FROM images').all().map(img => img.filename));
    const orphanFiles = allFiles.filter(file => !dbFilenames.has(file));
    
    const orphanDetails = [];
    for (const file of orphanFiles) {
        try {
            const stats = await fs.stat(path.join(uploadsDir, file));
            orphanDetails.push({ filename: file, size: stats.size, createdAt: stats.birthtime });
        } catch (e) { console.error(`无法获取文件信息: ${file}`, e); }
    }
    res.json(orphanDetails);
}));

apiAdminRouter.post('/maintenance/delete-orphans', handleApiError(async (req, res) => {
    const { filenames } = req.body;
    if (!Array.isArray(filenames) || filenames.length === 0) return res.status(400).json({ message: '未提供文件名。' });
    let deletedCount = 0; let errors = [];
    for (const filename of filenames) {
        if (filename.includes('..') || filename.includes('/')) { errors.push(`文件名无效: ${filename}`); continue; }
        try { await fs.unlink(path.join(uploadsDir, filename)); deletedCount++; } 
        catch (error) { errors.push(`无法删除 ${filename}: ${error.message}`); }
    }
    res.json({ message: `操作完成。成功删除 ${deletedCount} 个文件。`, errors });
}));

apiAdminRouter.post('/maintenance/clear-cache', handleApiError(async (req, res) => {
    const files = await fs.readdir(cacheDir);
    let deletedCount = 0;
    let errors = [];
    for (const file of files) {
        try {
            await fs.unlink(path.join(cacheDir, file));
            deletedCount++;
        } catch (error) {
            errors.push(`无法删除缓存文件 ${file}: ${error.message}`);
        }
    }
    res.json({ message: `操作完成。成功删除 ${deletedCount} 个缓存文件。`, errors: errors });
}));

apiAdminRouter.get('/2fa/status', handleApiError(async(req, res) => {
    const tfaConfig = getConfig('tfa');
    res.json({ enabled: !!(tfaConfig && tfaConfig.secret) });
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
        setConfig('tfa', { secret: secret });
        res.json({ message: '2FA 已成功启用！' });
    } else {
        res.status(400).json({ message: '验证码不正确。' });
    }
}));

apiAdminRouter.post('/2fa/disable', handleApiError(async (req, res) => {
    setConfig('tfa', null);
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

    echo "--> 正在生成数据迁移脚本 migrate-json-to-sqlite.js..."
cat << 'EOF' > migrate-json-to-sqlite.js
const fs = require('fs');
const path = require('path');
const Database = require('better-sqlite3');

const dataDir = path.join(__dirname, 'data');
const dbPath = path.join(dataDir, 'gallery.db');
const oldImagesPath = path.join(dataDir, 'images.json');
const oldCategoriesPath = path.join(dataDir, 'categories.json');
const oldConfigPath = path.join(dataDir, 'config.json');

const UNCATEGORIZED = '未分类';

function log(message, type = 'info') {
    const colorMap = {
        info: '\x1b[34m', // Blue
        success: '\x1b[32m', // Green
        warn: '\x1b[33m', // Yellow
        error: '\x1b[31m', // Red
        reset: '\x1b[0m'
    };
    console.log(`${colorMap[type]}%s${colorMap.reset}`, `[MIGRATE] ${message}`);
}

function isDbEmpty(db) {
    try {
        const result = db.prepare('SELECT COUNT(*) as count FROM images').get();
        return result.count === 0;
    } catch (error) {
        // 如果表不存在，也视为空
        return true;
    }
}

function readJsonFile(filePath, defaultValue = []) {
    try {
        if (fs.existsSync(filePath)) {
            const data = fs.readFileSync(filePath, 'utf-8');
            return data.trim() === '' ? defaultValue : JSON.parse(data);
        }
        return defaultValue;
    } catch (error) {
        log(`读取 JSON 文件失败: ${filePath}. 错误: ${error.message}`, 'error');
        return defaultValue;
    }
}

async function renameMigratedFiles() {
    const timestamp = new Date().getTime();
    const suffix = `.migrated_at_${timestamp}`;
    const files = [oldImagesPath, oldCategoriesPath, oldConfigPath];
    for (const file of files) {
        if (fs.existsSync(file)) {
            try {
                fs.renameSync(file, file + suffix);
                log(`已将旧文件 ${path.basename(file)} 重命名。`, 'info');
            } catch (error) {
                log(`重命名文件失败: ${file}. 错误: ${error.message}`, 'error');
            }
        }
    }
}

(async () => {
    log('开始执行数据迁移脚本...', 'info');

    if (!fs.existsSync(oldImagesPath) && !fs.existsSync(oldCategoriesPath)) {
        log('未找到旧的 JSON 数据文件，无需迁移。', 'warn');
        return;
    }

    let db;
    try {
        db = new Database(dbPath);

        if (!isDbEmpty(db)) {
            log('检测到 SQLite 数据库中已有数据，为防止数据覆盖，迁移已中止。', 'warn');
            log('如果确实需要重新迁移，请先备份并删除 gallery.db 文件。', 'warn');
            await renameMigratedFiles(); // 将旧文件重命名以防下次再次提示
            return;
        }

        log('数据库为空，准备开始迁移数据...', 'info');

        // 1. 迁移图片
        const images = readJsonFile(oldImagesPath, []);
        if (images.length > 0) {
            const insertImage = db.prepare(`
                INSERT OR IGNORE INTO images 
                (id, src, category, description, originalFilename, filename, size, uploadedAt, width, height, status, deletedAt) 
                VALUES (@id, @src, @category, @description, @originalFilename, @filename, @size, @uploadedAt, @width, @height, @status, @deletedAt)
            `);
            const migrateImages = db.transaction((imgs) => {
                for (const img of imgs) {
                    // 确保所有字段都存在，给予默认值
                    const imageToInsert = {
                        id: img.id || '',
                        src: img.src || '',
                        category: img.category || UNCATEGORIZED,
                        description: img.description || '',
                        originalFilename: img.originalFilename || path.basename(img.src),
                        filename: img.filename || path.basename(img.src),
                        size: img.size || 0,
                        uploadedAt: img.uploadedAt || new Date().toISOString(),
                        width: img.width || 0,
                        height: img.height || 0,
                        status: img.status || 'active',
                        deletedAt: img.deletedAt || null
                    };
                    insertImage.run(imageToInsert);
                }
            });
            migrateImages(images);
            log(`成功迁移 ${images.length} 条图片记录。`, 'success');
        } else {
            log('images.json 为空或不存在，跳过图片迁移。', 'info');
        }

        // 2. 迁移分类
        let categories = readJsonFile(oldCategoriesPath, []);
        if (!categories.includes(UNCATEGORIZED)) {
            categories.unshift(UNCATEGORIZED);
        }
        if (categories.length > 0) {
             const insertCategory = db.prepare('INSERT OR IGNORE INTO categories (name) VALUES (?)');
             const migrateCategories = db.transaction((cats) => {
                for (const cat of cats) insertCategory.run(cat);
             });
             migrateCategories(categories);
             log(`成功迁移 ${categories.length} 条分类记录。`, 'success');
        } else {
             log('categories.json 为空或不存在，跳过分类迁移。', 'info');
        }

        // 3. 迁移配置 (例如 2FA)
        const config = readJsonFile(oldConfigPath, {});
        if (Object.keys(config).length > 0) {
            const insertConfig = db.prepare('INSERT OR REPLACE INTO config (key, value) VALUES (?, ?)');
            const migrateConfig = db.transaction((conf) => {
                for (const [key, value] of Object.entries(conf)) {
                    insertConfig.run(key, JSON.stringify(value));
                }
            });
            migrateConfig(config);
            log(`成功迁移 ${Object.keys(config).length} 条配置项。`, 'success');
        } else {
            log('config.json 为空或不存在，跳过配置迁移。', 'info');
        }

        await renameMigratedFiles();
        log('🎉 数据迁移成功完成！', 'success');

    } catch (error) {
        log(`迁移过程中发生严重错误: ${error.message}`, 'error');
        console.error(error);
    } finally {
        if (db) {
            db.close();
        }
    }
})();
EOF

    echo "--> 正在生成后台管理页 public/admin.html... (有改动)"
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

        /* General Item Styles */
        .admin-image-item { position: relative; transition: opacity 0.4s ease, transform 0.4s ease; background-color: white; border-radius: 0.5rem; box-shadow: 0 1px 3px 0 rgba(0,0,0,.1), 0 1px 2px -1px rgba(0,0,0,.1); overflow: hidden; }
        .admin-image-item.fading-out { opacity: 0; transform: scale(0.95); }
        .admin-image-item .bulk-checkbox {
            display: none; /* Hidden by default, shown in select-mode */
            position: absolute; top: 0.75rem; left: 0.75rem; z-index: 10;
            width: 1.25rem; height: 1.25rem; border-radius: 0.25rem; cursor: pointer;
        }
        .select-mode-active .bulk-checkbox { display: block; }
        
        .description-clamp { display: -webkit-box; -webkit-box-orient: vertical; -webkit-line-clamp: 3; overflow: hidden; text-overflow: ellipsis; }

        .card-spinner { position: absolute; width: 1.5rem; height: 1.5rem; border: 3px solid rgba(0,0,0,0.1); border-top-color: #16a34a; border-radius: 50%; animation: spin 1s linear infinite; }
        @keyframes spin { to { transform: rotate(360deg); } }

        /* View-specific styles */
        #image-list.view-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(240px, 1fr)); gap: 1rem; }
        #image-list.view-list { display: flex; flex-direction: column; gap: 0.5rem; }

        /* Grid View Item */
        .admin-image-item.is-grid { display: flex; flex-direction: column; }
        .admin-image-item.is-grid .image-preview-container { height: 9rem; /* 144px */ }
        .admin-image-item.is-grid .image-info-wrapper { padding: 0.75rem; flex-grow: 1; display: flex; flex-direction: column; min-h-0; }
        
        /* List View Item */
        .admin-image-item.is-list { display: flex; align-items: center; padding: 0.5rem; gap: 1rem; }
        .admin-image-item.is-list .image-preview-container { height: 4rem; width: 4rem; flex-shrink: 0; }
        .admin-image-item.is-list .image-info-wrapper { display: grid; grid-template-columns: 2fr 1fr 1fr; gap: 1rem; flex-grow: 1; align-items: center; }
        .admin-image-item.is-list .info-col-1 { overflow: hidden; }
        .admin-image-item.is-list .info-col-2, .admin-image-item.is-list .info-col-3 { font-size: 0.875rem; color: #475569; }
        .admin-image-item.is-list .action-buttons { margin-left: auto; flex-shrink: 0; }
        .admin-image-item.is-list .bulk-checkbox { top: 50%; transform: translateY(-50%); }

        .image-preview-container { background-color: #f1f5f9; border-radius: 0.25rem; overflow: hidden; display: flex; align-items: center; justify-content: center; cursor: pointer; position: relative; }
        .image-preview-container img { width: 100%; height: 100%; object-fit: contain; opacity: 0; transition: opacity 0.4s ease-in-out; }
        .image-preview-container img.loaded { opacity: 1; }

        .page-item { transition: all 0.2s ease-in-out; }
        .page-item:not(.active):hover { background-color: #f1f5f9; }
        .page-item.active { background-color: #15803d; color: white; border-color: #14532d; font-weight: 700; transform: scale(1.1); z-index: 10; }

        /* Z-INDEX FIX: Establish a clear stacking order */
        .lightbox { z-index: 8000; }
        #generic-modal, #edit-image-modal, #tfa-modal { z-index: 9000; }
        
        .lightbox { position: fixed; top: 0; left: 0; width: 100%; height: 100%; background-color: rgba(0, 0, 0, 0.9); display: none; justify-content: center; align-items: center; opacity: 0; visibility: hidden; transition: opacity 0.3s ease; }
        .lightbox.active { opacity: 1; visibility: visible; }
        .lightbox .spinner { 
            display: none;
            position: absolute; 
            z-index: 1; 
            width: 3rem; 
            height: 3rem; 
            border: 4px solid rgba(255,255,255,0.2); 
            border-radius: 50%;
            border-top-color: rgba(255,255,255,0.8);
            animation: spin 1s linear infinite;
        }
        
        .lightbox-image { max-width: 85%; max-height: 85%; display: block; object-fit: contain; opacity: 0; transition: opacity 0.3s ease; }
        .lightbox-image.loaded { opacity: 1; }

        .lightbox-btn { position: absolute; top: 50%; transform: translateY(-50%); background-color: rgba(255,255,255,0.1); color: white; border: none; font-size: 2.5rem; cursor: pointer; padding: 0.5rem 1rem; border-radius: 0.5rem; transition: background-color 0.2s; z-index: 10;}
        .lightbox-btn:hover { background-color: rgba(255,255,255,0.2); }
        .lb-prev { left: 1rem; } .lb-next { right: 1rem; } .lb-close { top: 1rem; right: 1rem; font-size: 2rem; }
        .lb-counter { position: absolute; top: 1.5rem; left: 50%; transform: translateX(-50%); color: white; font-size: 1rem; background-color: rgba(0,0,0,0.3); padding: 0.25rem 0.75rem; border-radius: 9999px; }

        .lb-actions { position: absolute; bottom: 1rem; right: 1rem; display: flex; gap: 0.75rem; z-index: 10; }
        .lb-action-btn { color: white; border: none; padding: 0.5rem 1rem; border-radius: 0.5rem; cursor: pointer; transition: background-color 0.2s; font-size: 1rem; text-decoration: none; display: inline-flex; align-items: center; justify-content: center; }
        .lb-download { background-color: #22c55e; } .lb-download:hover { background-color: #16a34a; }
        .lb-delete { background-color: #ef4444; } .lb-delete:hover { background-color: #dc2626; }

        #image-list-section { display: flex; flex-direction: column; height: calc(100vh - 12rem); }
        #image-list-wrapper { flex-grow: 1; overflow-y: auto; padding: 0.25rem; }
        #pagination-container { flex-shrink: 0; position: sticky; bottom: 0; background: rgba(255, 255, 255, 0.85); backdrop-filter: blur(4px); padding: 1rem 0; border-top: 1px solid #e2e8f0; }
        
        #bulk-action-bar {
            position: fixed; bottom: 0; left: 0; right: 0; z-index: 25;
            background-color: rgba(17, 24, 39, 0.95); backdrop-filter: blur(8px); color: white;
            transform: translateY(100%); transition: transform 0.3s ease-in-out;
            box-shadow: 0 -4px 6px -1px rgb(0 0 0 / 0.1), 0 -2px 4px -2px rgb(0 0 0 / 0.1);
        }
        #bulk-action-bar.visible { transform: translateY(0); }
        
        #select-all-container, #bulk-cancel-btn { display: none; }
        .select-mode-active #select-all-container, .select-mode-active #bulk-cancel-btn { display: flex; }
        .select-mode-active #bulk-select-btn { display: none; }

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
            <section class="bg-white p-6 rounded-lg shadow-md"><h2 class="text-xl font-semibold mb-4">图库</h2><div id="navigation-list" class="space-y-1"><div id="nav-item-all" data-view="all" class="nav-item flex items-center gap-3 p-2 rounded cursor-pointer hover:bg-gray-100 active"><svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20" fill="currentColor" class="w-5 h-5 text-slate-500"><path fill-rule="evenodd" d="M1 5.25A2.25 2.25 0 013.25 3h13.5A2.25 2.25 0 0119 5.25v9.5A2.25 2.25 0 0116.75 17H3.25A2.25 2.25 0 011 14.75v-9.5zm1.5 5.81v3.69c0 .414.336.75.75.75h13.5a.75.75 0 00.75-.75v-3.69l-2.72-2.72a.75.75 0 00-1.06 0L11.5 10l-1.72-1.72a.75.75 0 00-1.06 0l-4 4zM12.5 7a1.5 1.5 0 11-3 0 1.5 1.5 0 013 0z" clip-rule="evenodd" /></svg><span class="category-name flex-grow">所有图片</span></div><div id="category-dynamic-list"></div><hr class="my-2"><div id="nav-item-recycle-bin" data-view="recycle_bin" class="nav-item flex items-center gap-3 p-2 rounded cursor-pointer hover:bg-gray-100"><svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20" fill="currentColor" class="w-5 h-5 text-slate-500"><path fill-rule="evenodd" d="M8.75 1A2.75 2.75 0 006 3.75V4.5h8V3.75A2.75 2.75 0 0011.25 1h-2.5zM10 4.5a.75.75 0 00-1.5 0v.75h1.5v-.75zM4.75 6.25A.75.75 0 015.5 5.5h9a.75.75 0 01.75.75v9a.75.75 0 01-.75.75h-9a.75.75 0 01-.75-.75v-9zM5.5 6.25v9h9v-9h-9z" clip-rule="evenodd" /></svg><span class="category-name flex-grow">回收站</span></div><hr class="my-2"><div id="nav-item-maintenance" data-view="maintenance" class="nav-item flex items-center gap-3 p-2 rounded cursor-pointer hover:bg-gray-100"><svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20" fill="currentColor" class="w-5 h-5 text-slate-500"><path d="M10.435 2.222a.75.75 0 0 0-1.026-.816l-6.5 3.25a.75.75 0 0 0 .816 1.026L8 3.91V15.5a.75.75 0 0 0 1.5 0V3.91l4.195 2.097a.75.75 0 0 0 .816-1.026l-4.125-2.065Z"></path><path d="M4.5 15.542a.75.75 0 0 0-1.5 0V17.5h-.5a.75.75 0 0 0 0 1.5h11a.75.75 0 0 0 0-1.5h-.5v-1.958a.75.75 0 0 0-1.5 0v1.208h-6v-1.208Z"></path></svg><span class="category-name flex-grow">空间清理</span></div></div></section>
            <section class="bg-white p-6 rounded-lg shadow-md"><h2 class="text-xl font-semibold mb-4">安全</h2><div id="security-section"></div></section>
        </div>
        <section id="image-list-section" class="bg-white p-6 rounded-lg shadow-md xl:col-span-8">
            <div class="flex flex-col md:flex-row justify-between items-center mb-4 gap-4 flex-shrink-0">
                <h2 id="image-list-header" class="text-xl font-semibold text-slate-900 flex-shrink-0"></h2>
                <div class="flex-grow flex flex-col sm:flex-row items-center gap-4 w-full">
                    <div id="view-controls" class="flex items-center gap-2">
                        <button id="bulk-select-btn" title="批量选择" class="flex items-center gap-1.5 px-3 py-1.5 border rounded-md text-sm hover:bg-slate-100"><svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20" fill="currentColor" class="w-5 h-5"><path fill-rule="evenodd" d="M10 2a.75.75 0 01.75.75v1.5a.75.75 0 01-1.5 0v-1.5A.75.75 0 0110 2zM8.06 4.94a.75.75 0 010-1.06l1.5-1.5a.75.75 0 011.06 0l1.5 1.5a.75.75 0 01-1.06 1.06L10 3.94 8.06 4.94zM5.75 6.75a.75.75 0 01.75-.75h7.5a.75.75 0 010 1.5h-7.5a.75.75 0 01-.75-.75zM5 10a.75.75 0 01.75-.75h4.5a.75.75 0 010 1.5h-4.5A.75.75 0 015 10zm0 3.75a.75.75 0 01.75-.75h4.5a.75.75 0 010 1.5h-4.5a.75.75 0 01-.75-.75zm8.5-4.5a.75.75 0 000 1.5h.01a.75.75 0 000-1.5h-.01zM13.5 13a.75.75 0 000 1.5h.01a.75.75 0 000-1.5h-.01z" clip-rule="evenodd" /><path fill-rule="evenodd" d="M3.5 1.75C2.672 1.75 2 2.422 2 3.25v13.5C2 17.578 2.672 18.25 3.5 18.25h13c.828 0 1.5-.672 1.5-1.5V3.25c0-.828-.672-1.5-1.5-1.5h-13zM3.5 3.25a.01.01 0 000 .01v13.5c0 .005.004.01.01.01h12.98a.01.01 0 00.01-.01V3.26a.01.01 0 000-.01H3.5z" clip-rule="evenodd" /></svg><span class="hidden sm:inline">批量选择</span></button>
                        <button id="bulk-cancel-btn" class="flex items-center gap-1.5 px-3 py-1.5 border rounded-md text-sm bg-red-100 text-red-700 hover:bg-red-200"><svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20" fill="currentColor" class="w-5 h-5"><path d="M6.28 5.22a.75.75 0 00-1.06 1.06L8.94 10l-3.72 3.72a.75.75 0 101.06 1.06L10 11.06l3.72 3.72a.75.75 0 101.06-1.06L11.06 10l3.72-3.72a.75.75 0 00-1.06-1.06L10 8.94 6.28 5.22z"></path></svg>取消</button>
                        <div id="select-all-container" class="items-center gap-2 pl-2">
                            <input type="checkbox" id="select-all-checkbox" class="h-4 w-4 rounded border-gray-300 text-indigo-600 focus:ring-indigo-500">
                            <label for="select-all-checkbox" class="text-sm text-slate-600">全选</label>
                        </div>
                    </div>
                    <div class="w-full md:w-64 ml-auto">
                        <input type="search" id="search-input" placeholder="在当前视图下搜索..." class="w-full border rounded-full px-4 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-green-500">
                    </div>
                </div>
                <div class="flex items-center gap-4 flex-shrink-0">
                    <select id="sort-select" class="border rounded-md px-2 py-1.5 text-sm focus:outline-none focus:ring-2 focus:ring-green-500">
                        <option value="date_desc">日期最新</option><option value="date_asc">日期最老</option>
                        <option value="name_asc">名称 A-Z</option><option value="name_desc">名称 Z-A</option>
                        <option value="size_desc">最大</option><option value="size_asc">最小</option>
                    </select>
                    <div id="view-toggle" class="flex items-center border rounded-md">
                        <button data-view="grid" class="p-1.5" title="网格视图"><svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20" fill="currentColor" class="w-5 h-5"><path fill-rule="evenodd" d="M4.25 2A2.25 2.25 0 002 4.25v2.5A2.25 2.25 0 004.25 9h2.5A2.25 2.25 0 009 6.75v-2.5A2.25 2.25 0 006.75 2h-2.5zm0 9A2.25 2.25 0 002 13.25v2.5A2.25 2.25 0 004.25 18h2.5A2.25 2.25 0 009 15.75v-2.5A2.25 2.25 0 006.75 11h-2.5zm9-9A2.25 2.25 0 0011 4.25v2.5A2.25 2.25 0 0013.25 9h2.5A2.25 2.25 0 0018 6.75v-2.5A2.25 2.25 0 0015.75 2h-2.5zM13.25 11a2.25 2.25 0 00-2.25 2.25v2.5a2.25 2.25 0 002.25 2.25h2.5a2.25 2.25 0 002.25-2.25v-2.5a2.25 2.25 0 00-2.25-2.25h-2.5z" clip-rule="evenodd"></path></svg></button>
                        <button data-view="list" class="p-1.5" title="列表视图"><svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20" fill="currentColor" class="w-5 h-5"><path d="M3 4.75A.75.75 0 013.75 4h12.5a.75.75 0 010 1.5H3.75A.75.75 0 013 4.75zM3 9.75A.75.75 0 013.75 9h12.5a.75.75 0 010 1.5H3.75A.75.75 0 013 9.75zM3 14.75A.75.75 0 013.75 14h12.5a.75.75 0 010 1.5H3.75A.75.75 0 013 14.75z"></path></svg></button>
                    </div>
                </div>
            </div>
            <div id="image-list-wrapper">
                <div id="image-list"></div>
                <div id="image-loader" class="text-center py-8 text-slate-500 hidden">正在加载...</div>
                 <div id="maintenance-view" class="hidden p-4 space-y-6"></div>
            </div>
            <div id="pagination-container" class="mt-auto flex justify-center items-center gap-4">
                <div id="items-per-page-container">
                    <select id="items-per-page-select" class="border rounded-md px-2 py-1 text-sm focus:outline-none">
                        <option value="12">12 / 页</option><option value="24">24 / 页</option><option value="48">48 / 页</option><option value="96">96 / 页</option>
                    </select>
                </div>
                <div id="page-links-container"></div>
            </div>
        </section>
    </main>
    <div id="generic-modal" class="modal fixed inset-0 bg-black bg-opacity-50 items-center justify-center p-4"><div class="bg-white rounded-lg shadow-xl p-6 w-full max-w-sm"><h3 id="modal-title" class="text-lg font-bold mb-4"></h3><div id="modal-body" class="mb-4 text-slate-600"></div><div id="modal-footer" class="flex justify-end space-x-2"></div></div></div>
    <div id="edit-image-modal" class="modal fixed inset-0 bg-black bg-opacity-50 items-center justify-center p-4"><div class="bg-white rounded-lg shadow-xl p-6 w-full max-w-md"><h3 class="text-lg font-bold mb-4">编辑图片信息</h3><form id="edit-image-form"><input type="hidden" id="edit-id"><div class="mb-4"><label for="edit-originalFilename" class="block text-sm font-medium mb-1">原始文件名</label><input type="text" id="edit-originalFilename" class="w-full border rounded px-3 py-2"></div><div class="mb-4"><label for="edit-category-select" class="block text-sm font-medium mb-1">分类</label><select id="edit-category-select" class="w-full border rounded px-3 py-2"></select></div><div class="mb-4"><label for="edit-description" class="block text-sm font-medium mb-1">描述</label><textarea id="edit-description" rows="3" class="w-full border rounded px-3 py-2"></textarea></div><div class="flex justify-end space-x-2 mt-6"><button type="button" class="modal-cancel-btn bg-gray-300 hover:bg-gray-400 text-black py-2 px-4 rounded">取消</button><button type="submit" class="bg-blue-600 hover:bg-blue-700 text-white py-2 px-4 rounded">保存更改</button></div></form></div></div>
    <div id="tfa-modal" class="modal fixed inset-0 bg-black bg-opacity-50 items-center justify-center p-4"><div class="bg-white rounded-lg shadow-xl p-6 w-full max-w-md"><h3 class="text-lg font-bold mb-4">设置两步验证 (2FA)</h3><div id="tfa-setup-content"></div><div class="flex justify-end space-x-2 mt-6"><button type="button" class="modal-cancel-btn bg-gray-300 hover:bg-gray-400 text-black py-2 px-4 rounded">关闭</button></div></div></div>
    <div id="lightbox" class="lightbox">
        <div class="spinner"></div>
        <span id="lb-counter" class="lb-counter"></span>
        <button class="lightbox-btn lb-close">&times;</button>
        <button class="lightbox-btn lb-prev">&lsaquo;</button>
        <img class="lightbox-image" alt="">
        <button class="lightbox-btn lb-next">&rsaquo;</button>
        <div class="lb-actions">
            <a href="#" id="lb-download" download class="lb-action-btn lb-download">下载</a>
            <button id="lb-delete" title="移至回收站" class="lb-action-btn lb-delete">删除</button>
        </div>
    </div>
    <div id="bulk-action-bar">
        <div class="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-3">
            <div class="flex items-center justify-between">
                <div class="flex items-center gap-4">
                     <span id="bulk-counter" class="font-medium">已选择 0 张图片</span>
                </div>
                <div id="bulk-buttons-container" class="flex items-center gap-3">
                    </div>
            </div>
        </div>
    </div>
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
            paginationContainer: document.getElementById('pagination-container'), pageLinksContainer: document.getElementById('page-links-container'),
            itemsPerPageSelect: document.getElementById('items-per-page-select'),
            sortSelect: document.getElementById('sort-select'), viewToggle: document.getElementById('view-toggle'), viewControls: document.getElementById('view-controls'),
            maintenanceView: document.getElementById('maintenance-view'), imageListWrapper: document.getElementById('image-list-wrapper'),
            lightbox: document.getElementById('lightbox'),
            lightboxSpinner: document.querySelector('#lightbox .spinner'),
            lightboxImage: document.querySelector('#lightbox .lightbox-image'),
            lightboxCounter: document.getElementById('lb-counter'),
            lightboxDownloadLink: document.getElementById('lb-download'),
            lightboxDeleteBtn: document.getElementById('lb-delete'),
            bulkActionBar: document.getElementById('bulk-action-bar'), bulkCounter: document.getElementById('bulk-counter'),
            bulkButtonsContainer: document.getElementById('bulk-buttons-container'), selectAllContainer: document.getElementById('select-all-container'),
            selectAllCheckbox: document.getElementById('select-all-checkbox'),
            bulkSelectBtn: document.getElementById('bulk-select-btn'), bulkCancelBtn: document.getElementById('bulk-cancel-btn'),
            imageListSection: document.getElementById('image-list-section'),
        };
        let filesToUpload = []; let allLoadedImages = []; let currentImageIndex = 0; let currentSearchTerm = ''; let debounceTimer; let currentAdminPage = 1; let loadingSpinnerTimeout;
        let selectedImageIds = new Set();
        let isInSelectMode = false;
        let currentViewMode = localStorage.getItem('adminViewMode') || 'grid';
        let itemsPerPage = parseInt(localStorage.getItem('adminItemsPerPage') || '12', 10);
        
        const apiRequest = async (url, options = {}) => {
            try {
                const response = await fetch(url, options);
                if (response.status === 401) { showToast('登录状态已过期', 'error'); setTimeout(() => window.location.href = '/login.html', 2000); throw new Error('Unauthorized'); }
                if (!response.ok) { let errorMsg = `HTTP Error: ${response.status} ${response.statusText}`; try { const errorJson = await response.json(); errorMsg = errorJson.message || errorMsg; } catch (e) {} throw new Error(errorMsg); }
                return response;
            } catch (error) { if (error instanceof TypeError) { throw new Error('网络错误，请检查您的连接。'); } throw error; }
        };
        const formatBytes = (bytes, decimals = 2) => { if (!+bytes) return '0 Bytes'; const k = 1024; const dm = decimals < 0 ? 0 : decimals; const sizes = ["Bytes", "KB", "MB", "GB", "TB"]; const i = Math.floor(Math.log(bytes) / Math.log(k)); return `${parseFloat((bytes / Math.pow(k, i)).toFixed(dm))} ${sizes[i]}`; };
        const showToast = (message, type = 'success') => { const toast = document.getElementById('toast'); toast.className = `toast max-w-xs text-white text-sm rounded-lg shadow-lg p-3 ${type === 'success' ? 'bg-green-600' : 'bg-red-600'}`; toast.querySelector('#toast-message').textContent = message; toast.querySelector('#toast-icon').innerHTML = type === 'success' ? `<svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M5 13l4 4L19 7"></path></svg>` : `<svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 8v4m0 4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z"></path></svg>`; toast.style.display = 'block'; setTimeout(() => toast.classList.add('show'), 10); setTimeout(() => { toast.classList.remove('show'); setTimeout(() => toast.style.display = 'none', 300); }, 3000); };
        const showGenericModal = (title, bodyHtml, footerHtml) => { DOMElements.genericModal.querySelector('#modal-title').textContent = title; DOMElements.genericModal.querySelector('#modal-body').innerHTML = bodyHtml; DOMElements.genericModal.querySelector('#modal-footer').innerHTML = footerHtml; DOMElements.genericModal.classList.add('active'); };
        const showConfirmationModal = (title, bodyHtml, confirmText = '确认', cancelText = '取消') => { return new Promise(resolve => { const footerHtml = `<button type="button" class="modal-cancel-btn bg-gray-300 hover:bg-gray-400 text-black py-2 px-4 rounded">${cancelText}</button><button type="button" id="modal-confirm-btn" class="bg-red-600 hover:bg-red-700 text-white py-2 px-4 rounded">${confirmText}</button>`; showGenericModal(title, bodyHtml, footerHtml); DOMElements.genericModal.querySelector('#modal-confirm-btn').onclick = () => { hideModal(DOMElements.genericModal); resolve(true); }; const cancelBtn = DOMElements.genericModal.querySelector('.modal-cancel-btn'); cancelBtn.onclick = () => { hideModal(DOMElements.genericModal); resolve(false); }; DOMElements.genericModal.onclick = (e) => { if (e.target === DOMElements.genericModal) { cancelBtn.click(); } }; }); };
        const hideModal = (modal) => modal.classList.remove('active');
        const toggleSelectMode = (forceOff = false) => {
            isInSelectMode = forceOff ? false : !isInSelectMode;
            DOMElements.imageListSection.classList.toggle('select-mode-active', isInSelectMode);
            if (!isInSelectMode) { resetSelection(); }
        };
        DOMElements.bulkSelectBtn.addEventListener('click', () => toggleSelectMode());
        DOMElements.bulkCancelBtn.addEventListener('click', () => toggleSelectMode(true));
        const updateBulkActionBar = () => {
            const count = selectedImageIds.size;
            DOMElements.bulkCounter.textContent = `已选择 ${count} 张图片`;
            if (count > 0) {
                DOMElements.bulkActionBar.classList.add('visible');
                generateBulkActionButtons();
            } else {
                DOMElements.bulkActionBar.classList.remove('visible');
            }
            DOMElements.selectAllCheckbox.checked = count > 0 && allLoadedImages.length > 0 && count === allLoadedImages.length;
        };
        const generateBulkActionButtons = () => {
            DOMElements.bulkButtonsContainer.innerHTML = '';
            const isRecycleBin = document.querySelector('#nav-item-recycle-bin').classList.contains('active');
            const createButton = (id, text, classes) => { const btn = document.createElement('button'); btn.id = id; btn.textContent = text; btn.className = `px-4 py-2 text-sm font-medium rounded-md shadow-sm transition-colors ${classes}`; DOMElements.bulkButtonsContainer.appendChild(btn); };
            if (isRecycleBin) {
                createButton('bulk-restore-btn', '批量恢复', 'bg-blue-600 hover:bg-blue-700 text-white');
                createButton('bulk-purge-btn', '批量彻底删除', 'bg-red-700 hover:bg-red-800 text-white');
            } else {
                createButton('bulk-description-btn', '修改描述', 'bg-sky-500 hover:bg-sky-600 text-white');
                createButton('bulk-recategorize-btn', '修改分类', 'bg-yellow-500 hover:bg-yellow-600 text-white');
                createButton('bulk-delete-btn', '移至回收站', 'bg-red-600 hover:bg-red-700 text-white');
            }
        };
        const resetSelection = () => {
            selectedImageIds.clear();
            document.querySelectorAll('.bulk-checkbox').forEach(cb => cb.checked = false);
            updateBulkActionBar();
        };
        const performBulkAction = async (action, payload = {}) => {
            const ids = Array.from(selectedImageIds);
            try {
                await apiRequest('/api/admin/images/bulk-action', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ action, ids, payload }) });
                showToast(`批量操作成功！`);
                resetSelection();
                toggleSelectMode(true);
                changePage(currentAdminPage, false);
            } catch (error) { showToast(`批量操作失败: ${error.message}`, 'error'); }
        };
        
        DOMElements.addCategoryBtn.addEventListener('click', () => { showGenericModal( '添加新分类', '<form id="add-cat-form"><label for="new-cat-name" class="sr-only">分类名称</label><input type="text" id="new-cat-name" placeholder="输入新分类的名称" required class="w-full border rounded px-3 py-2"></form>', '<button type="button" class="modal-cancel-btn bg-gray-300 hover:bg-gray-400 text-black py-2 px-4 rounded">取消</button><button type="submit" form="add-cat-form" class="bg-blue-600 hover:bg-blue-700 text-white py-2 px-4 rounded">保存</button>'); const form = document.getElementById('add-cat-form'); const input = document.getElementById('new-cat-name'); input.focus(); form.addEventListener('submit', async (e) => { e.preventDefault(); const name = input.value.trim(); if (!name) return; try { await apiRequest('/api/admin/categories', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ name }) }); hideModal(DOMElements.genericModal); showToast('分类添加成功'); await refreshAllData(); } catch (error) { showToast(`添加失败: ${error.message}`, 'error'); } }); DOMElements.genericModal.querySelector('.modal-cancel-btn').addEventListener('click', () => hideModal(DOMElements.genericModal)); });
        const handleFileSelection = (fileList) => { const imageFiles = Array.from(fileList).filter(f => f.type.startsWith('image/')); const currentFilenames = new Set(filesToUpload.map(item => item.file.name)); const newFiles = imageFiles.filter(f => !currentFilenames.has(f.name)).map(file => ({ file, description: DOMElements.unifiedDescription.value, userHasTyped: DOMElements.unifiedDescription.value !== '', shouldRename: false, status: 'pending' })); filesToUpload.push(...newFiles); DOMElements.uploadBtn.disabled = filesToUpload.length === 0; renderFilePreviews(); };
        const renderFilePreviews = () => { if (filesToUpload.length === 0) { DOMElements.filePreviewContainer.classList.add('hidden'); return; } DOMElements.filePreviewList.innerHTML = ''; let totalSize = 0; filesToUpload.forEach((item, index) => { totalSize += item.file.size; const listItem = document.createElement('div'); const tempId = `file-preview-${index}`; listItem.className = 'file-preview-item text-slate-600 border rounded p-2'; listItem.dataset.fileIndex = index; listItem.innerHTML = `<div class="flex items-start"><img class="w-12 h-12 object-cover rounded mr-3 bg-slate-100" id="thumb-${tempId}"><div class="flex-grow"><div class="flex justify-between items-center text-xs mb-1"><p class="truncate pr-2 font-medium">${item.file.name}</p><button type="button" data-index="${index}" class="remove-file-btn text-xl text-red-500 hover:text-red-700 leading-none">&times;</button></div><p class="text-xs text-slate-500">${formatBytes(item.file.size)}</p></div></div><input type="text" data-index="${index}" class="relative w-full text-xs border rounded px-2 py-1 description-input bg-transparent mt-2" placeholder="添加独立描述..." value="${item.description}"><p class="upload-status text-xs mt-1"></p>`; DOMElements.filePreviewList.appendChild(listItem); const reader = new FileReader(); reader.onload = (e) => { document.getElementById(`thumb-${tempId}`).src = e.target.result; }; reader.readAsDataURL(item.file); }); DOMElements.uploadSummary.textContent = `已选择 ${filesToUpload.length} 个文件，总大小: ${formatBytes(totalSize)}`; DOMElements.filePreviewContainer.classList.remove('hidden'); };
        const dz = DOMElements.dropZone; dz.addEventListener('dragover', (e) => { e.preventDefault(); dz.classList.add('bg-green-50', 'border-green-400'); }); dz.addEventListener('dragleave', (e) => dz.classList.remove('bg-green-50', 'border-green-400')); dz.addEventListener('drop', (e) => { e.preventDefault(); dz.classList.remove('bg-green-50', 'border-green-400'); handleFileSelection(e.dataTransfer.files); });
        DOMElements.imageInput.addEventListener('change', (e) => { handleFileSelection(e.target.files); e.target.value = ''; });
        DOMElements.unifiedDescription.addEventListener('input', e => { const unifiedText = e.target.value; document.querySelectorAll('.file-preview-item').forEach(item => { const index = parseInt(item.dataset.fileIndex, 10); if (filesToUpload[index] && !filesToUpload[index].userHasTyped) { item.querySelector('.description-input').value = unifiedText; filesToUpload[index].description = unifiedText; } }); });
        DOMElements.filePreviewList.addEventListener('input', e => { if (e.target.classList.contains('description-input')) { const index = parseInt(e.target.dataset.index, 10); if(filesToUpload[index]) { filesToUpload[index].description = e.target.value; filesToUpload[index].userHasTyped = true; } } });
        DOMElements.filePreviewList.addEventListener('click', e => { if (e.target.classList.contains('remove-file-btn')) { const index = parseInt(e.target.dataset.index, 10); filesToUpload.splice(index, 1); renderFilePreviews(); DOMElements.uploadBtn.disabled = filesToUpload.length === 0; } });
        const processUploadQueue = async (e) => {
            e.preventDefault(); DOMElements.uploadBtn.disabled = true; const pendingFiles = filesToUpload.filter(f => f.status === 'pending');
            if (pendingFiles.length === 0) { showToast("没有需要上传的新文件。", "error"); DOMElements.uploadBtn.disabled = filesToUpload.length === 0; return; }
            try { const filenamesToCheck = pendingFiles.map(item => item.file.name); const response = await apiRequest('/api/admin/check-filenames', { method: 'POST', headers: {'Content-Type': 'application/json'}, body: JSON.stringify({filenames: filenamesToCheck}) }); const { duplicates } = await response.json();
                for (const item of pendingFiles) { if (duplicates.includes(item.file.name)) { const userConfirmed = await showConfirmationModal('文件已存在', `文件 "<strong>${item.file.name}</strong>" 已存在。是否仍然继续上传？<br>(新文件将被自动重命名)`, '继续上传', '取消此文件'); if (userConfirmed) { item.shouldRename = true; } else { item.status = 'cancelled'; const previewItem = DOMElements.filePreviewList.querySelector(`[data-file-index="${filesToUpload.indexOf(item)}"]`); if(previewItem) previewItem.querySelector('.upload-status').textContent = '已取消'; } } }
            } catch (error) { showToast(`检查文件名出错: ${error.message}`, 'error'); DOMElements.uploadBtn.disabled = false; return; }
            const uploadableFiles = filesToUpload.filter(f => f.status === 'pending'); let processedCount = 0; const updateButtonText = () => { DOMElements.uploadBtn.textContent = `正在上传 (${processedCount}/${uploadableFiles.length})...`; }; if (uploadableFiles.length > 0) updateButtonText();
            for (const item of uploadableFiles) { const originalIndex = filesToUpload.indexOf(item); const previewItem = DOMElements.filePreviewList.querySelector(`[data-file-index="${originalIndex}"]`); if (!previewItem) { processedCount++; updateButtonText(); continue; } const statusEl = previewItem.querySelector('.upload-status');
                try { statusEl.textContent = '上传中...'; const formData = new FormData(); formData.append('image', item.file); formData.append('category', DOMElements.categorySelect.value); formData.append('description', item.description); formData.append('rename', item.shouldRename); await apiRequest('/api/admin/upload', { method: 'POST', body: formData }); item.status = 'success'; previewItem.classList.add('upload-success'); statusEl.textContent = '✅ 上传成功'; } catch (err) { if (err.message !== 'Unauthorized') { item.status = 'error'; statusEl.textContent = `❌ ${err.message}`; previewItem.classList.add('upload-error'); } } finally { processedCount++; updateButtonText(); }
            }
            showToast(`所有任务处理完成。`); DOMElements.uploadBtn.textContent = '上传文件'; filesToUpload = []; DOMElements.imageInput.value = ''; DOMElements.unifiedDescription.value = '';
            setTimeout(() => { DOMElements.filePreviewContainer.classList.add('hidden'); DOMElements.uploadBtn.disabled = true; }, 3000); await refreshAllData();
        };
        DOMElements.uploadForm.addEventListener('submit', processUploadQueue);
        
        async function refreshAllData() { await refreshNavigation(); const activeNav = document.querySelector('.nav-item.active'); if (activeNav) { activeNav.click(); } else { document.getElementById('nav-item-all').click(); } }
        async function populateCategorySelects(selectedCategory = null) { try { const response = await apiRequest('/api/categories'); const categories = await response.json(); [DOMElements.categorySelect, DOMElements.editCategorySelect].forEach(select => { const currentVal = select.value; select.innerHTML = ''; categories.forEach(cat => select.add(new Option(cat, cat))); select.value = categories.includes(currentVal) ? currentVal : selectedCategory || categories[0] || ''; }); } catch (error) { if (error.message !== 'Unauthorized') console.error('加载分类失败:', error.message); } }
        async function refreshNavigation() { try { const response = await apiRequest('/api/categories'); const categories = await response.json(); DOMElements.categoryDynamicList.innerHTML = ''; categories.forEach(cat => { const isUncategorized = cat === UNCATEGORIZED; const item = document.createElement('div'); item.className = 'nav-item flex items-center justify-between p-2 rounded cursor-pointer hover:bg-gray-100'; item.dataset.view = 'category'; item.dataset.categoryName = cat; item.innerHTML = `<span class="category-name flex-grow">${cat}</span>` + (isUncategorized ? '' : `<div class="space-x-2 flex-shrink-0 opacity-0 group-hover:opacity-100 transition-opacity"><button data-name="${cat}" class="rename-cat-btn text-blue-500 hover:text-blue-700 text-sm">重命名</button><button data-name="${cat}" class="delete-cat-btn text-red-500 hover:red-700 text-sm">删除</button></div>`); item.addEventListener('mouseenter', () => item.classList.add('group')); item.addEventListener('mouseleave', () => item.classList.remove('group')); DOMElements.categoryDynamicList.appendChild(item); }); await populateCategorySelects(); } catch (error) { if (error.message !== 'Unauthorized') console.error('加载导航列表失败:', error.message); } }
        function switchMainView(viewType) {
            DOMElements.imageListWrapper.style.display = viewType === 'content' ? 'block' : 'none';
            DOMElements.paginationContainer.style.display = viewType === 'content' ? 'flex' : 'none';
            DOMElements.viewControls.style.display = viewType === 'content' ? 'flex' : 'none';
            DOMElements.maintenanceView.style.display = viewType === 'maintenance' ? 'block' : 'none';
        }
        async function loadContent(url, headerText) {
            DOMElements.imageLoader.classList.remove('hidden'); DOMElements.imageList.innerHTML = '';
            try {
                const response = await apiRequest(url);
                const data = await response.json();
                allLoadedImages = data.images;
                DOMElements.imageListHeader.innerHTML = `${headerText} <span class="text-base text-gray-500 font-normal">(共 ${data.totalImages} 张)</span>`;
                if (allLoadedImages.length === 0) { DOMElements.imageList.innerHTML = '<p class="text-slate-500 col-span-full text-center py-10">没有找到图片。</p>'; } 
                else { allLoadedImages.forEach((image) => renderAdminImage(image, headerText.includes('回收站'))); }
                renderPaginationControls(data.page, data.totalPages);
            } catch (error) { if (error.message !== 'Unauthorized') DOMElements.imageList.innerHTML = `<p class="text-red-500 col-span-full text-center py-10">加载内容失败: ${error.message}</p>`; } 
            finally { DOMElements.imageLoader.classList.add('hidden'); }
        }
        async function loadImages(category, name) { switchMainView('content'); const sortBy = DOMElements.sortSelect.value; const url = `/api/images?category=${category}&search=${encodeURIComponent(currentSearchTerm)}&page=${currentAdminPage}&limit=${itemsPerPage}&sort_by=${sortBy}`; await loadContent(url, name); }
        async function loadRecycleBin() { switchMainView('content'); const sortBy = DOMElements.sortSelect.value; const url = `/api/admin/recycle-bin?search=${encodeURIComponent(currentSearchTerm)}&page=${currentAdminPage}&limit=${itemsPerPage}&sort_by=${sortBy}`; await loadContent(url, '回收站'); }
        function renderAdminImage(image, isRecycleBinView = false) {
            const item = document.createElement('div'); item.className = `admin-image-item is-${currentViewMode}`; item.dataset.id = image.id;
            const buttonsHtml = isRecycleBinView
                ? `<button title="恢复" class="restore-btn p-2 rounded-full text-green-600 hover:bg-green-100" data-id="${image.id}"><svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor" class="w-5 h-5 pointer-events-none"><path stroke-linecap="round" stroke-linejoin="round" d="M9 15L3 9m0 0l6-6M3 9h12a6 6 0 010 12h-3" /></svg></button><button title="彻底删除" class="purge-btn p-2 rounded-full text-red-500 hover:bg-red-100" data-id="${image.id}"><svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor" class="w-5 h-5 pointer-events-none"><path stroke-linecap="round" stroke-linejoin="round" d="M14.74 9l-.346 9m-4.788 0L9.26 9m9.968-3.21c.342.052.682.107 1.022.166m-1.022-.165L18.16 19.673a2.25 2.25 0 01-2.244 2.077H8.084a2.25 2.25 0 01-2.244-2.077L4.772 5.79m14.456 0a48.108 48.108 0 00-3.478-.397m-12 .562c.34-.059.68-.114 1.022-.165m0 0a48.11 48.11 0 013.478-.397m7.5 0v-.916c0-1.18-.91-2.134-2.036-2.134H8.718c-1.126 0-2.037.955-2.037 2.134v.916m7.5 0a48.667 48.667 0 00-7.5 0" /></svg></button>`
                : `<a href="${image.src}" download="${image.originalFilename}" title="下载" class="p-2 rounded-full text-slate-600 hover:bg-slate-200"><svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor" class="w-5 h-5"><path stroke-linecap="round" stroke-linejoin="round" d="M3 16.5v2.25A2.25 2.25 0 005.25 21h13.5A2.25 2.25 0 0021 18.75V16.5M16.5 12L12 16.5m0 0L7.5 12m4.5 4.5V3" /></svg></a><button title="编辑" class="edit-btn p-2 rounded-full text-slate-600 hover:bg-slate-200" data-id="${image.id}"><svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor" class="w-5 h-5 pointer-events-none"><path stroke-linecap="round" stroke-linejoin="round" d="M16.862 4.487l1.687-1.688a1.875 1.875 0 112.652 2.652L6.832 19.82a4.5 4.5 0 01-1.897 1.13l-2.685.8.8-2.685a4.5 4.5 0 011.13-1.897L16.863 4.487zm0 0L19.5 7.125" /></svg></button><button title="移至回收站" class="delete-btn p-2 rounded-full text-red-500 hover:bg-red-100" data-id="${image.id}"><svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor" class="w-5 h-5 pointer-events-none"><path stroke-linecap="round" stroke-linejoin="round" d="M14.74 9l-.346 9m-4.788 0L9.26 9m9.968-3.21c.342.052.682.107 1.022.166m-1.022-.165L18.16 19.673a2.25 2.25 0 01-2.244 2.077H8.084a2.25 2.25 0 01-2.244-2.077L4.772 5.79m14.456 0a48.108 48.108 0 00-3.478-.397m-12 .562c.34-.059.68-.114 1.022-.165m0 0a48.11 48.11 0 013.478-.397m7.5 0v-.916c0-1.18-.91-2.134-2.036-2.134H8.718c-1.126 0-2.037.955-2.037 2.134v.916m7.5 0a48.667 48.667 0 00-7.5 0" /></svg></button>`;
            
            if (currentViewMode === 'grid') {
                item.innerHTML = `<input type="checkbox" class="bulk-checkbox" data-id="${image.id}"><a href="#" class="image-preview-container flex-shrink-0 preview-trigger" data-id="${image.id}"><div class="card-spinner"></div><img src="/image-proxy/${image.filename}?w=400" alt="${image.description || image.originalFilename}" class="pointer-events-none" onload="this.classList.add('loaded'); this.previousElementSibling.style.display='none';"></a><div class="image-info-wrapper"><p class="font-bold text-sm truncate" title="${image.originalFilename}">${image.originalFilename}</p><div class="flex justify-between items-center text-xs text-slate-500 my-2"><span class="flex items-center gap-1.5" title="文件大小"><svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" fill="currentColor" class="w-3.5 h-3.5"><path d="M2 3.5A1.5 1.5 0 0 1 3.5 2h9A1.5 1.5 0 0 1 14 3.5v9a1.5 1.5 0 0 1-1.5 1.5h-9A1.5 1.5 0 0 1 2 12.5v-9ZM3.5 3a.5.5 0 0 0-.5.5v9a.5.5 0 0 0 .5.5h9a.5.5 0 0 0 .5-.5v-9a.5.5 0 0 0-.5-.5h-9Z" /><path d="M5 5.5A.5.5 0 0 1 5.5 5h5a.5.5 0 0 1 0 1h-5A.5.5 0 0 1 5 5.5Zm0 2A.5.5 0 0 1 5.5 7h5a.5.5 0 0 1 0 1h-5A.5.5 0 0 1 5 7.5Zm0 2A.5.5 0 0 1 5.5 9h3a.5.5 0 0 1 0 1h-3A.5.5 0 0 1 5 9.5Z" /></svg>${formatBytes(image.size)}</span><span class="flex items-center gap-1.5 truncate" title="尺寸"><svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" fill="currentColor" class="w-3.5 h-3.5"><path d="M1.5 2.5A1 1 0 0 1 2.5 1.5h11A1 1 0 0 1 15 2.5v11a1 1 0 0 1-1 1h-11a1 1 0 0 1-1-1v-11zM2.5 2a.5.5 0 0 0-.5.5v11a.5.5 0 0 0 .5.5h11a.5.5 0 0 0 .5-.5v-11a.5.5 0 0 0-.5-.5h-11z" /><path d="M4.25 10.75a.75.75 0 0 1 0-1.5h1.5a.75.75 0 0 1 0 1.5h-1.5zM10.25 5a.75.75 0 0 1 0 1.5h-5.5a.75.75 0 0 1 0-1.5h5.5zM4.75 5.25a.75.75 0 0 1 1.5 0v5.5a.75.75 0 0 1-1.5 0v-5.5z" /></svg>${image.width}x${image.height}</span></div><p class="text-xs text-slate-600 flex-grow pt-1" title="${image.description || ''}"><span class="description-clamp">${image.description || '无描述'}</span></p>${isRecycleBinView ? `<p class="text-xs text-red-500 mt-auto pt-2"><strong>删除于:</strong> ${new Date(image.deletedAt).toLocaleString()}</p>` : ''}<div class="bg-slate-50 p-1 flex justify-end items-center gap-1 mt-auto flex-shrink-0 -mx-3 -mb-3"><button title="预览" class="preview-btn p-2 rounded-full text-slate-600 hover:bg-slate-200" data-id="${image.id}"><svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor" class="w-5 h-5 pointer-events-none"><path stroke-linecap="round" stroke-linejoin="round" d="M2.036 12.322a1.012 1.012 0 010-.639C3.423 7.51 7.36 4.5 12 4.5c4.638 0 8.573 3.007 9.963 7.178.07.207.07.431 0 .639C20.577 16.49 16.64 19.5 12 19.5c-4.638 0-8.573-3.007-9.963-7.178z" /><path stroke-linecap="round" stroke-linejoin="round" d="M15 12a3 3 0 11-6 0 3 3 0 016 0z" /></svg></button>${buttonsHtml}</div></div>`;
            } else { item.innerHTML = `<input type="checkbox" class="bulk-checkbox" data-id="${image.id}"><a href="#" class="image-preview-container flex-shrink-0 preview-trigger" data-id="${image.id}"><div class="card-spinner"></div><img src="/image-proxy/${image.filename}?w=100" alt="${image.description || image.originalFilename}" class="pointer-events-none" onload="this.classList.add('loaded'); this.previousElementSibling.style.display='none';"></a><div class="image-info-wrapper"><div class="info-col-1"><p class="font-bold text-sm truncate" title="${image.originalFilename}">${image.originalFilename}</p><p class="text-xs text-slate-500 truncate" title="${image.description || ''}">${image.description || '无描述'}</p></div><div class="info-col-2"><p class="truncate" title="分类: ${image.category}">${image.category || UNCATEGORIZED}</p><p class="text-xs text-slate-500">${new Date(isRecycleBinView ? image.deletedAt : image.uploadedAt).toLocaleDateString()}</p></div><div class="info-col-3"><p>${formatBytes(image.size)}</p><p class="text-xs text-slate-500">${image.width} x ${image.height}</p></div></div><div class="action-buttons flex items-center gap-1"><button title="预览" class="preview-btn p-2 rounded-full text-slate-600 hover:bg-slate-200" data-id="${image.id}"><svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor" class="w-5 h-5 pointer-events-none"><path stroke-linecap="round" stroke-linejoin="round" d="M2.036 12.322a1.012 1.012 0 010-.639C3.423 7.51 7.36 4.5 12 4.5c4.638 0 8.573 3.007 9.963 7.178.07.207.07.431 0 .639C20.577 16.49 16.64 19.5 12 19.5c-4.638 0-8.573-3.007-9.963-7.178z" /><path stroke-linecap="round" stroke-linejoin="round" d="M15 12a3 3 0 11-6 0 3 3 0 016 0z" /></svg></button>${buttonsHtml}</div>`; }
            DOMElements.imageList.appendChild(item);
        }
        const changePage = (page, resetPage = true) => {
            currentAdminPage = resetPage ? 1 : page; const activeNav = document.querySelector('.nav-item.active'); if (!activeNav) return;
            const view = activeNav.dataset.view; const categoryName = activeNav.dataset.categoryName; const headerText = activeNav.querySelector('.category-name')?.textContent || '所有图片';
            resetSelection(); DOMElements.imageList.innerHTML = ''; DOMElements.imageLoader.classList.remove('hidden');
            if (view === 'recycle_bin') { loadRecycleBin(); } else if (view === 'maintenance') { loadMaintenanceView(); } else { loadImages(categoryName || 'all', headerText); }
        };
        function renderPaginationControls(currentPage, totalPages) {
            DOMElements.pageLinksContainer.innerHTML = ''; if (totalPages <= 1) return;
            let html = '<div class="flex items-center space-x-1">'; const createBtnHTML = (text, page, disabled = false, active = false) => `<button data-page="${page}" class="page-item px-3 py-1 text-sm font-medium border border-gray-300 rounded-md ${disabled ? 'opacity-50 cursor-not-allowed' : ''} ${active ? 'active' : ''}">${text}</button>`;
            html += createBtnHTML('上一页', currentPage - 1, currentPage === 1);
            let pages = []; if (totalPages <= 7) { for (let i = 1; i <= totalPages; i++) pages.push(i); }
            else { pages.push(1); if (currentPage > 3) pages.push('...'); let start = Math.max(2, currentPage - 1); let end = Math.min(totalPages - 1, currentPage + 1); for (let i = start; i <= end; i++) pages.push(i); if (currentPage < totalPages - 2) pages.push('...'); pages.push(totalPages); }
            pages.forEach(p => { if (p === '...') html += '<span class="px-3 py-1 text-sm">...</span>'; else html += createBtnHTML(p, p, false, p === currentPage); });
            html += createBtnHTML('下一页', currentPage + 1, currentPage === totalPages); html += '</div>';
            DOMElements.pageLinksContainer.innerHTML = html;
        }
        DOMElements.pageLinksContainer.addEventListener('click', e => { const target = e.target.closest('.page-item'); if(!target || target.disabled || target.classList.contains('active')) return; e.preventDefault(); const newPage = parseInt(target.dataset.page); changePage(newPage, false); });
        DOMElements.navigationList.addEventListener('click', async (e) => {
            const navItem = e.target.closest('.nav-item'); if (!navItem) return;
            if (e.target.matches('.rename-cat-btn, .delete-cat-btn')) { 
                e.preventDefault(); e.stopPropagation(); const catName = e.target.dataset.name; 
                if (e.target.classList.contains('rename-cat-btn')) { 
                    showGenericModal(`重命名分类 "${catName}"`, '<form id="modal-form"><input type="text" id="modal-input" required class="w-full border rounded px-3 py-2"></form>', '<button type="button" class="modal-cancel-btn bg-gray-300 hover:bg-gray-400 text-black py-2 px-4 rounded">取消</button><button type="submit" form="modal-form" class="bg-blue-600 hover:bg-blue-700 text-white py-2 px-4 rounded">保存</button>'); 
                    const input = document.getElementById('modal-input'); input.value = catName; DOMElements.genericModal.querySelector('.modal-cancel-btn').onclick=() => hideModal(DOMElements.genericModal); 
                    document.getElementById('modal-form').onsubmit = async (ev) => { ev.preventDefault(); const newName = input.value.trim(); if (!newName || newName === catName) { hideModal(DOMElements.genericModal); return; } try { await apiRequest('/api/admin/categories', { method: 'PUT', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ oldName: catName, newName }) }); hideModal(DOMElements.genericModal); showToast('重命名成功'); await refreshAllData(); } catch (error) { showToast(`重命名失败: ${error.message}`, 'error'); } }; 
                } else if (e.target.classList.contains('delete-cat-btn')) { 
                    const confirmed = await showConfirmationModal('确认删除', `<p>确定要删除分类 "<strong>${catName}</strong>" 吗？<br>此分类下的图片将归入 "未分类"。</p>`, '确认删除'); 
                    if(confirmed) { try { await apiRequest('/api/admin/categories', { method: 'DELETE', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ name: catName }) }); showToast('删除成功'); await refreshAllData(); } catch (error) { showToast(`删除失败: ${error.message}`, 'error'); } } 
                } 
                return; 
            }
            e.preventDefault(); document.querySelectorAll('.nav-item').forEach(el => el.classList.remove('active')); navItem.classList.add('active');
            DOMElements.searchInput.value = ''; currentSearchTerm = ''; toggleSelectMode(true); changePage(1, true);
        });
        DOMElements.imageList.addEventListener('click', async (e) => {
            const target = e.target; const imageItem = target.closest('.admin-image-item'); if (!imageItem) return; const imageId = imageItem.dataset.id;
            if (target.matches('.bulk-checkbox')) { if (target.checked) { selectedImageIds.add(imageId); } else { selectedImageIds.delete(imageId); } updateBulkActionBar(); return; }
            const button = target.closest('button, a'); if (!button) return;
            if (button.tagName === 'A' && button.hasAttribute('download')) { return; } e.preventDefault();
            const image = allLoadedImages.find(img => img.id === imageId);
            if (button.matches('.preview-trigger, .preview-btn')) { const newIndex = allLoadedImages.findIndex(img => img.id === imageId); if (newIndex === -1) { showToast('无法在列表中找到此图片。', 'error'); return; } DOMElements.lightbox.classList.add('active'); document.body.classList.add('lightbox-open'); showImageAtIndex(newIndex); }
            else if (button.matches('.edit-btn')) { if (!image) return; await populateCategorySelects(image.category); DOMElements.editImageModal.querySelector('#edit-id').value = image.id; DOMElements.editImageModal.querySelector('#edit-originalFilename').value = image.originalFilename; DOMElements.editImageModal.querySelector('#edit-description').value = image.description; DOMElements.editImageModal.classList.add('active'); }
            else if (button.matches('.delete-btn')) { if (!image) return; const confirmed = await showConfirmationModal('移至回收站', `<p>确定要将图片 "<strong>${image.originalFilename}</strong>" 移至回收站吗？</p>`, '确认移动'); if (confirmed) { try { await apiRequest(`/api/admin/images/${imageId}`, { method: 'DELETE' }); showToast('图片已移至回收站'); if (imageItem) { imageItem.classList.add('fading-out'); setTimeout(() => imageItem.remove(), 400); } const imageIndex = allLoadedImages.findIndex(i => i.id === imageId); if (imageIndex > -1) allLoadedImages.splice(imageIndex, 1); } catch (error) { showToast(error.message, 'error'); } } }
            else if (button.matches('.restore-btn')) { try { await apiRequest(`/api/admin/recycle-bin/${imageId}/restore`, { method: 'POST' }); showToast('图片已恢复'); if(imageItem) { imageItem.classList.add('fading-out'); setTimeout(() => imageItem.remove(), 400); } const imageIndex = allLoadedImages.findIndex(i => i.id === imageId); if (imageIndex > -1) allLoadedImages.splice(imageIndex, 1); } catch (error) { showToast(error.message, 'error'); } }
            else if (button.matches('.purge-btn')) { const confirmed = await showConfirmationModal('彻底删除', `<p>确定要永久删除这张图片吗？<br><strong>此操作无法撤销。</strong></p>`, '确认删除'); if (confirmed) { try { await apiRequest(`/api/admin/recycle-bin/${imageId}/purge`, { method: 'DELETE' }); showToast('图片已彻底删除'); if(imageItem) { imageItem.classList.add('fading-out'); setTimeout(() => imageItem.remove(), 400); } const imageIndex = allLoadedImages.findIndex(i => i.id === imageId); if (imageIndex > -1) allLoadedImages.splice(imageIndex, 1); } catch (error) { showToast(error.message, 'error'); } } }
        });
        DOMElements.selectAllCheckbox.addEventListener('change', (e) => { const isChecked = e.target.checked; const checkboxes = DOMElements.imageList.querySelectorAll('.bulk-checkbox'); checkboxes.forEach(cb => { const id = cb.dataset.id; cb.checked = isChecked; if (isChecked) { selectedImageIds.add(id); } else { selectedImageIds.delete(id); } }); updateBulkActionBar(); });
        DOMElements.bulkButtonsContainer.addEventListener('click', async (e) => {
            const target = e.target.closest('button'); if (!target) return;
            switch(target.id) {
                case 'bulk-delete-btn': { const c = await showConfirmationModal('批量移至回收站', `<p>确定要将选中的 <strong>${selectedImageIds.size}</strong> 张图片移至回收站吗？</p>`, '确认移动'); if (c) performBulkAction('delete'); break; }
                case 'bulk-restore-btn': { const c = await showConfirmationModal('批量恢复', `<p>确定要恢复选中的 <strong>${selectedImageIds.size}</strong> 张图片吗？</p>`, '确认恢复'); if (c) performBulkAction('restore'); break; }
                case 'bulk-purge-btn': { const c = await showConfirmationModal('批量彻底删除', `<p>确定要永久删除选中的 <strong>${selectedImageIds.size}</strong> 张图片吗？<br><strong>此操作无法撤销！</strong></p>`, '确认删除'); if (c) performBulkAction('purge'); break; }
                case 'bulk-recategorize-btn': { const r = await apiRequest('/api/categories'); const c = await r.json(); let o = c.map(cat => `<option value="${cat}">${cat}</option>`).join(''); showGenericModal('批量修改分类', `<form id="recategorize-form"><p class="mb-2 text-sm">为选中的 ${selectedImageIds.size} 张图片选择一个新的分类：</p><select id="bulk-category-select" class="w-full border rounded px-3 py-2">${o}</select></form>`, '<button type="button" class="modal-cancel-btn bg-gray-300 hover:bg-gray-400 text-black py-2 px-4 rounded">取消</button><button type="submit" form="recategorize-form" class="bg-blue-600 hover:bg-blue-700 text-white py-2 px-4 rounded">应用</button>'); document.getElementById('recategorize-form').onsubmit = (ev) => { ev.preventDefault(); const newCategory = document.getElementById('bulk-category-select').value; hideModal(DOMElements.genericModal); performBulkAction('recategorize', { newCategory }); }; DOMElements.genericModal.querySelector('.modal-cancel-btn').onclick = () => hideModal(DOMElements.genericModal); break; }
                case 'bulk-description-btn': { showGenericModal('批量修改描述', '<form id="desc-form"><p class="text-sm mb-2">输入新描述，它将【完全覆盖】所有选中图片的现有描述。</p><textarea id="bulk-new-description" class="w-full border rounded p-2" rows="4"></textarea></form>', '<button type="button" class="modal-cancel-btn bg-gray-300 hover:bg-gray-400 text-black py-2 px-4 rounded">取消</button><button type="submit" form="desc-form" class="bg-blue-600 hover:bg-blue-700 text-white py-2 px-4 rounded">应用</button>'); document.getElementById('desc-form').onsubmit = async (ev) => { ev.preventDefault(); const newDescription = document.getElementById('bulk-new-description').value; hideModal(DOMElements.genericModal); const confirmed = await showConfirmationModal('确认覆盖描述', `<p class="text-red-600 font-bold">警告！</p><p>此操作将用新描述【完全覆盖】所有 <strong>${selectedImageIds.size}</strong> 张选中图片的现有描述，旧描述将会丢失。确定要继续吗？</p>`, '确认覆盖', '取消'); if (confirmed) { performBulkAction('edit_description', { newDescription }); } }; DOMElements.genericModal.querySelector('.modal-cancel-btn').onclick = () => hideModal(DOMElements.genericModal); break; }
            }
        });
        DOMElements.editImageForm.addEventListener('submit', async (e) => { e.preventDefault(); const id = document.getElementById('edit-id').value; const body = JSON.stringify({ originalFilename: document.getElementById('edit-originalFilename').value, category: DOMElements.editCategorySelect.value, description: document.getElementById('edit-description').value }); try { await apiRequest(`/api/admin/images/${id}`, { method: 'PUT', headers: { 'Content-Type': 'application/json' }, body }); hideModal(DOMElements.editImageModal); showToast('更新成功'); changePage(currentAdminPage, false); } catch (error) { showToast(`更新失败: ${error.message}`, 'error'); } });
        async function renderSecuritySection() { try { const response = await apiRequest('/api/admin/2fa/status'); const { enabled } = await response.json(); let content; if (enabled) { content = `<p class="text-sm text-slate-600 mb-3">两步验证 (2FA) 当前已<span class="font-bold text-green-600">启用</span>。</p><button id="disable-tfa-btn" class="w-full bg-red-600 hover:bg-red-700 text-white font-bold py-2 px-4 rounded-lg">禁用 2FA</button>`; } else { content = `<p class="text-sm text-slate-600 mb-3">通过启用两步验证，为您的账户增加一层额外的安全保障。</p><button id="enable-tfa-btn" class="w-full bg-blue-600 hover:bg-blue-700 text-white font-bold py-2 px-4 rounded-lg">启用 2FA</button>`; } DOMElements.securitySection.innerHTML = content; } catch (error) { DOMElements.securitySection.innerHTML = `<p class="text-red-500">无法加载安全状态: ${error.message}</p>`; } }
        DOMElements.securitySection.addEventListener('click', async e => { if (e.target.id === 'enable-tfa-btn') { try { const response = await apiRequest('/api/admin/2fa/generate', {method: 'POST'}); const data = await response.json(); DOMElements.tfaModal.querySelector('#tfa-setup-content').innerHTML = `<p class="text-sm mb-4">1. 使用您的 Authenticator 应用扫描二维码。</p><img src="${data.qrCode}" alt="2FA QR Code" class="mx-auto border p-2 bg-white"><p class="text-sm mt-4 mb-2">或手动输入密钥:</p><p class="font-mono bg-gray-100 p-2 rounded text-center text-sm break-all">${data.secret}</p><p class="text-sm mt-6 mb-2">2. 输入应用生成的6位验证码以完成设置：</p><form id="tfa-verify-form" class="flex gap-2"><input type="text" id="tfa-token-input" required maxlength="6" class="w-full border rounded px-3 py-2" placeholder="6位数字码"><button type="submit" class="bg-green-600 hover:bg-green-700 text-white py-2 px-4 rounded">验证并启用</button></form><p id="tfa-error" class="text-red-500 text-sm mt-2 hidden"></p>`; DOMElements.tfaModal.classList.add('active'); document.getElementById('tfa-verify-form').addEventListener('submit', async ev => { ev.preventDefault(); const token = document.getElementById('tfa-token-input').value; try { await apiRequest('/api/admin/2fa/enable', {method: 'POST', headers: {'Content-Type': 'application/json'}, body: JSON.stringify({ secret: data.secret, token })}); hideModal(DOMElements.tfaModal); showToast('2FA 已成功启用！'); await renderSecuritySection(); } catch (err) { document.getElementById('tfa-error').textContent = err.message; document.getElementById('tfa-error').classList.remove('hidden'); } }); } catch (error) { showToast(error.message, 'error'); } } else if (e.target.id === 'disable-tfa-btn') { const confirmed = await showConfirmationModal('禁用 2FA', `<p>确定要禁用两步验证吗？您的账户安全性将会降低。</p>`, '确认禁用'); if (confirmed) { try { await apiRequest('/api/admin/2fa/disable', {method: 'POST'}); showToast('2FA已禁用'); await renderSecuritySection(); } catch(err) { showToast(err.message, 'error'); } } } });
        async function loadMaintenanceView() {
            switchMainView('maintenance'); DOMElements.imageListHeader.textContent = '空间清理';
            DOMElements.maintenanceView.innerHTML = `<div class="bg-slate-50 p-6 rounded-lg"><h3 class="text-lg font-semibold mb-2">清理冗余文件</h3><p class="text-sm text-slate-600 mb-4">扫描 uploads 目录中存在，但数据库记录里却不存在的“孤立”文件。</p><button id="scan-orphans-btn" class="bg-blue-600 hover:bg-blue-700 text-white font-bold py-2 px-4 rounded-lg">开始扫描</button><div id="orphan-results" class="mt-6 hidden"></div></div><div class="bg-slate-50 p-6 rounded-lg"><h3 class="text-lg font-semibold mb-2">清理图片缓存</h3><p class="text-sm text-slate-600 mb-4">安全地删除所有由程序动态生成的图片缩略图缓存 (位于 public/cache 目录)。</p><button id="clear-cache-btn" class="bg-orange-500 hover:bg-orange-600 text-white font-bold py-2 px-4 rounded-lg">开始清理缓存</button></div>`;
        }
        DOMElements.maintenanceView.addEventListener('click', async e => {
            if (e.target.id === 'scan-orphans-btn') {
                const btn = e.target; btn.disabled = true; btn.textContent = '扫描中...'; const resultsContainer = document.getElementById('orphan-results');
                try {
                    const res = await apiRequest('/api/admin/maintenance/find-orphans'); const orphans = await res.json(); resultsContainer.classList.remove('hidden');
                    if (orphans.length === 0) { resultsContainer.innerHTML = '<p class="text-green-600 font-medium">太棒了！没有发现任何冗余文件。</p>'; return; }
                    resultsContainer.innerHTML = `<h4 class="font-semibold mb-2">扫描结果：发现 ${orphans.length} 个冗余文件</h4><div class="flex items-center gap-2 mb-2"><input type="checkbox" id="select-all-orphans"><label for="select-all-orphans">全选</label></div><div id="orphan-list" class="border rounded max-h-72 overflow-y-auto p-2 space-y-1">${orphans.map(f => `<div class="flex items-center gap-2 text-sm"><input type="checkbox" class="orphan-checkbox" value="${f.filename}"><span>${f.filename} (${formatBytes(f.size)})</span></div>`).join('')}</div><button id="delete-orphans-btn" class="mt-4 bg-red-600 hover:bg-red-700 text-white font-bold py-2 px-4 rounded-lg" disabled>删除选中文件</button>`;
                } catch (err) { resultsContainer.innerHTML = `<p class="text-red-500">扫描失败: ${err.message}</p>`; } finally { btn.disabled = false; btn.textContent = '重新扫描'; }
            } else if (e.target.id === 'delete-orphans-btn') {
                const checked = Array.from(document.querySelectorAll('.orphan-checkbox:checked')).map(cb => cb.value); if (checked.length === 0) return;
                const confirmed = await showConfirmationModal('确认删除', `确定要永久删除这 ${checked.length} 个冗余文件吗？此操作无法撤销。`, '确认删除');
                if (confirmed) {
                    try {
                        const res = await apiRequest('/api/admin/maintenance/delete-orphans', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ filenames: checked }) });
                        const result = await res.json(); showToast(result.message);
                        if(result.errors && result.errors.length > 0) { showToast(`发生错误: ${result.errors.join(', ')}`, 'error'); }
                        document.getElementById('scan-orphans-btn').click();
                    } catch (err) { showToast(`删除失败: ${err.message}`, 'error'); }
                }
            } else if (e.target.id === 'select-all-orphans') { document.querySelectorAll('.orphan-checkbox').forEach(cb => cb.checked = e.target.checked);
            } else if (e.target.id === 'clear-cache-btn') {
                 const confirmed = await showConfirmationModal('确认清理缓存', `确定要删除所有图片缓存吗？此操作安全，缓存会在需要时自动重建。`, '确认清理', '取消');
                 if (confirmed) {
                    const btn = e.target; btn.disabled = true; btn.textContent = '清理中...';
                    try {
                         const res = await apiRequest('/api/admin/maintenance/clear-cache', { method: 'POST' });
                         const result = await res.json(); showToast(result.message);
                         if(result.errors && result.errors.length > 0) { showToast(`清理缓存时发生错误`, 'error'); }
                    } catch (err) { showToast(`清理失败: ${err.message}`, 'error'); }
                    finally { btn.disabled = false; btn.textContent = '开始清理缓存'; }
                 }
            }
            const deleteBtn = document.getElementById('delete-orphans-btn'); if (deleteBtn) { deleteBtn.disabled = !Array.from(document.querySelectorAll('.orphan-checkbox')).some(cb => cb.checked); }
        });
        const updateAdminLightboxContent = (item) => { DOMElements.lightboxImage.alt = item.description || item.originalFilename; DOMElements.lightboxDownloadLink.href = item.src; DOMElements.lightboxDownloadLink.download = item.originalFilename; const isRecycleBinView = document.querySelector('#nav-item-recycle-bin').classList.contains('active'); DOMElements.lightboxDeleteBtn.style.display = isRecycleBinView ? 'none' : 'inline-flex'; };
        const showImageAtIndex = (index) => {
            if (index < 0 || index >= allLoadedImages.length) return; currentImageIndex = index; const item = allLoadedImages[currentImageIndex]; if (!item) return;
            DOMElements.lightboxImage.classList.remove('loaded'); DOMElements.lightboxCounter.textContent = `${currentImageIndex + 1} / ${allLoadedImages.length}`; updateAdminLightboxContent(item);
            clearTimeout(loadingSpinnerTimeout); loadingSpinnerTimeout = setTimeout(() => { DOMElements.lightboxSpinner.style.display = 'block'; }, 200);
            DOMElements.lightboxImage.src = `/image-proxy/${item.filename}`;
        };
        const showNextImage = () => showImageAtIndex((currentImageIndex + 1) % allLoadedImages.length);
        const showPrevImage = () => showImageAtIndex((currentImageIndex - 1 + allLoadedImages.length) % allLoadedImages.length);
        const closeLightbox = () => { DOMElements.lightbox.classList.remove('active'); document.body.classList.remove('lightbox-open'); };
        DOMElements.lightbox.addEventListener('click', async (e) => { 
            const target = e.target.closest('button, a') || e.target; 
            if (target.matches('.lb-next')) { showNextImage(); } else if (target.matches('.lb-prev')) { showPrevImage(); } else if (target.matches('.lb-close') || e.target === DOMElements.lightbox) { closeLightbox(); } 
            else if (target.id === 'lb-delete') { const imageToDelete = allLoadedImages[currentImageIndex]; if (!imageToDelete) return; const confirmed = await showConfirmationModal('移至回收站', `<p>确定要将图片 "<strong>${imageToDelete.originalFilename}</strong>" 移至回收站吗？</p>`, '确认移动', '取消'); if (confirmed) { try { await apiRequest(`/api/admin/images/${imageToDelete.id}`, { method: 'DELETE' }); showToast('图片已移至回收站'); const cardToRemove = DOMElements.imageList.querySelector(`.admin-image-item[data-id='${imageToDelete.id}']`); if (cardToRemove) { cardToRemove.classList.add('fading-out'); setTimeout(() => cardToRemove.remove(), 400); } allLoadedImages.splice(currentImageIndex, 1); if (allLoadedImages.length === 0) { closeLightbox(); changePage(currentAdminPage, false); } else { if (currentImageIndex >= allLoadedImages.length) { currentImageIndex = allLoadedImages.length - 1; } showImageAtIndex(currentImageIndex); } } catch (error) { showToast(error.message, 'error'); } } } 
        });
        const applyViewMode = (mode) => { DOMElements.imageList.className = `view-${mode}`; DOMElements.viewToggle.querySelectorAll('button').forEach(b => b.classList.toggle('bg-slate-200', b.dataset.view === mode)); DOMElements.imageList.innerHTML = ''; allLoadedImages.forEach(img => renderAdminImage(img, document.querySelector('#nav-item-recycle-bin').classList.contains('active'))); };
        DOMElements.viewToggle.addEventListener('click', (e) => { const button = e.target.closest('button'); if (button && button.dataset.view !== currentViewMode) { currentViewMode = button.dataset.view; localStorage.setItem('adminViewMode', currentViewMode); applyViewMode(currentViewMode); } });
        DOMElements.itemsPerPageSelect.addEventListener('change', () => { itemsPerPage = parseInt(DOMElements.itemsPerPageSelect.value, 10); localStorage.setItem('adminItemsPerPage', itemsPerPage); changePage(1, true); });
        DOMElements.sortSelect.addEventListener('change', () => changePage(1, true));
        DOMElements.searchInput.addEventListener('input', () => { clearTimeout(debounceTimer); debounceTimer = setTimeout(() => { currentSearchTerm = DOMElements.searchInput.value.trim(); changePage(1, true); }, 500); });
        document.addEventListener('keydown', e => { if (DOMElements.lightbox.classList.contains('active')) { if (e.key === 'ArrowRight') showNextImage(); if (e.key === 'ArrowLeft') showPrevImage(); if (e.key === 'Escape') closeLightbox(); } });
        [DOMElements.genericModal, DOMElements.editImageModal, DOMElements.tfaModal].forEach(modal => { const cancelBtn = modal.querySelector('.modal-cancel-btn'); if(cancelBtn) { cancelBtn.addEventListener('click', () => hideModal(modal)); } modal.addEventListener('click', (e) => { if (e.target.matches('.modal')) hideModal(modal); }); });
        async function init() {
            DOMElements.itemsPerPageSelect.value = itemsPerPage; DOMElements.viewToggle.querySelector(`button[data-view="${currentViewMode}"]`).classList.add('bg-slate-200'); DOMElements.imageList.className = `view-${currentViewMode}`;
            DOMElements.lightboxImage.onload = () => { clearTimeout(loadingSpinnerTimeout); DOMElements.lightboxSpinner.style.display = 'none'; DOMElements.lightboxImage.classList.add('loaded'); };
            DOMElements.lightboxImage.onerror = () => { clearTimeout(loadingSpinnerTimeout); DOMElements.lightboxSpinner.style.display = 'none'; showToast('无法加载预览图片', 'error'); };
            await Promise.all([refreshNavigation(), renderSecuritySection()]);
            DOMElements.navigationList.querySelector('#nav-item-all').click();
        }
        init();
    });
    </script>
</body>
</html>
EOF

    echo "--> 正在生成登录页 public/login.html... (无改动)"
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

# --- 管理菜单功能 ---
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

    # --- 数据迁移逻辑 ---
    if [ -f "data/images.json" ]; then
        echo -e "${YELLOW}--> 检测到旧的 JSON 数据文件。${NC}"
        read -p "$(echo -e "是否要将旧的 JSON 数据迁移到新的 SQLite 数据库? (此操作只应执行一次) ${PROMPT_Y}: ")" migrate_confirm
        if [[ "$migrate_confirm" == "y" || "$migrate_confirm" == "Y" ]]; then
            echo -e "${YELLOW}--> 正在执行数据迁移脚本...${NC}"
            if npm run migrate; then
                echo -e "${GREEN}--> 数据迁移脚本执行成功！${NC}"
            else
                echo -e "${RED}--> 数据迁移失败！请检查上面的日志输出。${NC}"
            fi
        else
            echo -e "${YELLOW}--> 已跳过数据迁移。旧的JSON文件将被保留。${NC}"
        fi
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
    echo -e "${YELLOW}--- 1. 安装 / 更新应用 ---${NC}"
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
    check_and_install_deps "SQLite3 Dev Library (for better-sqlite3)" "libsqlite3-dev sqlite-devel" "sqlite3.h" "${sudo_cmd}" || return 1


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
    local package_names=$2
    local command_to_check=$3
    local sudo_cmd=$4

    # 特殊处理头文件检查
    if [[ "$command_to_check" == *.h ]]; then
        # 在标准 include 路径中查找头文件
        if [ -f "/usr/include/${command_to_check}" ] || [ -f "/usr/include/x86_64-linux-gnu/${command_to_check}" ] || find /usr/include -name "${command_to_check}" | grep -q .; then
             return 0
        fi
    elif command -v "$command_to_check" &> /dev/null; then
        return 0
    fi
    
    echo -e "${YELLOW}--> 检测到核心依赖 '${dep_to_check}' 未安装，正在尝试自动安装...${NC}"
    
    local pm_cmd=""
    local package_name=""

    if command -v apt-get &> /dev/null; then
        pm_cmd="apt-get install -y"
        package_name=$(echo "$package_names" | awk '{print $1}') # Debian/Ubuntu
        echo "--> 检测到 APT 包管理器，正在更新..."
        ${sudo_cmd} apt-get update -y
    elif command -v dnf &> /dev/null; then
        pm_cmd="dnf install -y"
        package_name=$(echo "$package_names" | awk '{print $2}') # Fedora/CentOS 8+
        echo "--> 检测到 DNF 包管理器..."
    elif command -v yum &> /dev/null; then
        pm_cmd="yum install -y"
        package_name=$(echo "$package_names" | awk '{print $2}') # CentOS 7
        echo "--> 检测到 YUM 包管理器..."
    else
        echo -e "${RED}错误: 未找到 apt, dnf 或 yum 包管理器。请手动安装 '${dep_to_check}' (${package_names})。${NC}"
        return 1
    fi

    if [ -z "$package_name" ]; then
        package_name=$(echo "$package_names" | awk '{print $1}')
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
        
        if [ -f "${INSTALL_DIR}/data/gallery.db" ]; then
            printf "  %-15s %b%s%b\n" "数据库引擎:" "${GREEN}" "SQLite" "${NC}"
        else
             printf "  %-15s %b%s%b\n" "数据库引擎:" "${YELLOW}" "未初始化" "${NC}"
        fi

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
    echo -e "${YELLOW}--- 修改后台用户/密码 ---${NC}"
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
    [ ! -d "${INSTALL_DIR}" ] || [ ! -f "${INSTALL_DIR}/data/gallery.db" ] && { echo -e "${RED}错误: 应用未安装或数据库文件不存在。${NC}"; return 1; }
    
    echo "请注意：2FA 的启用/禁用/重置现在推荐在后台管理的“安全”页面进行操作。"
    read -p "您是否仍要在此处通过删除配置的方式强制重置 2FA？这在您丢失验证器时有用。(${GREEN}y${NC}/${RED}n${NC}): " force_reset
    if [[ "$force_reset" == "y" || "$force_reset" == "Y" ]]; then
         echo -e "${YELLOW}正在通过 SQLite 命令强制移除 2FA 配置...${NC}"
         sqlite3 "${INSTALL_DIR}/data/gallery.db" "DELETE FROM config WHERE key = 'tfa';"
         echo -e "${GREEN}2FA 配置已从数据库中移除。${NC}"
         echo -e "${YELLOW}请注意：这仅移除了服务器端的密钥。您需要手动从您的 Authenticator 应用中删除旧的条目。${NC}"
         echo -e "${YELLOW}正在重启应用...${NC}"
         restart_app
    else
        echo -e "${YELLOW}操作已取消。${NC}"
    fi
}

backup_data() {
    echo -e "${YELLOW}--- 开始数据备份 ---${NC}"
    [ ! -d "${INSTALL_DIR}" ] && { echo -e "${RED}错误: 应用未安装，无法备份。${NC}"; return 1; }

    mkdir -p "${BACKUP_DIR}"
    local TIMESTAMP; TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")
    local BACKUP_FILE="${BACKUP_DIR}/image-gallery-backup-${TIMESTAMP}.tar.gz"

    echo "--> 需要备份的目录/文件:"
    echo "    - ${INSTALL_DIR}/data/gallery.db (数据库)"
    echo "    - ${INSTALL_DIR}/public/uploads (全部图片)"
    echo "    - ${INSTALL_DIR}/.env (配置文件)"
    
    echo "--> 正在创建备份文件: ${BACKUP_FILE}..."
    if tar -czf "${BACKUP_FILE}" -C "${INSTALL_DIR}" data/gallery.db public/uploads .env; then
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
    echo -e "${RED}此操作将【覆盖】当前所有的图片、数据库和配置！${NC}"
    echo -e "${RED}它会用您选择的备份文件替换以下所有内容:${NC}"
    echo -e "${RED}  - ${INSTALL_DIR}/data/gallery.db (数据库)${NC}"
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
    mkdir -p "${INSTALL_DIR}/data" "${INSTALL_DIR}/public"

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
    echo -e "${RED}     (包括所有程序、配置、图片、缓存和数据库文件)${NC}"
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
    echo -e "   8. 强制重置 2FA"
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
