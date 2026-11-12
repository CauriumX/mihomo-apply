# CauriumX mihomo-apply

> 版本化发布产物。模板与规则集同版本，通过 jsDelivr 分发。

## 仓库定位

本仓库是唯一有发布副作用的地方，也是订阅链路的实际数据源。

```
mihomo-rules      ← 规则集候选
mihomo-template   ← 模板源
    │ 审核通过
    ▼
mihomo-apply      ← 本仓库：v0.1.0/ v0.1.1/ … + latest
    │ jsDelivr CDN
    ▼
客户端
```

## 版本目录

每个版本是完整快照，不可变：

```
v0.1.0/
  site/*.mrs          19 个域名规则集
  geoip/*.mrs         3 个 IP 规则集
  Crypto.mrs
  PayPal.txt
  PayPal-Phish.txt
  template.yaml       渲染后的模板（URL 已指向 v0.1.0）
  MANIFEST.json       所有产物的 sha256
latest -> v0.1.0
VERSION
CHANGELOG.md
```

## 为什么模板和规则集同版本

模板源里写的是占位符：

```yaml
url: ".../mihomo-apply@{{RULES_VERSION}}/site/AI-Site.mrs"
```

发布时替换为具体 tag：

```yaml
url: ".../mihomo-apply@v0.1.0/site/AI-Site.mrs"
```

这样模板与规则集不可能错配。旧架构的缺陷是模板锁 commit 而规则集漂 `@main`，回滚时两者不兼容。

## 使用

### 订阅地址

```
https://cdn.jsdelivr.net/gh/CauriumX/mihomo-apply@latest/template.yaml
```

### 规则集直连

```yaml
rule-providers:
  AI-Site:
    url: "https://cdn.jsdelivr.net/gh/CauriumX/mihomo-apply@v0.1.0/site/AI-Site.mrs"
```

## 发布流程

```
1. 从 mihomo-rules 取候选产物
2. 从 mihomo-template 取模板源
3. 渲染模板（{{RULES_VERSION}} → v0.1.0）
4. 复制产物到 v0.1.0/
5. 计算 sha256，写 MANIFEST.json
6. 更新 VERSION + CHANGELOG
7. 提交 + 打 tag v0.1.0
8. 切 latest 符号链接
9. 等 CDN 刷新（约 5-10 分钟）
10. 验证：从 CDN 拉取，比对 sha256
```

## 回滚

```sh
ln -sfn v0.1.0 latest
git commit -m "rollback to v0.1.0"
git tag v0.1.1   # 新 tag 指向旧内容
```

不删旧版本。`v0.1.0` 永远存在，只是 `latest` 不再指向它。

## 版本号规则

| 变化类型 | 版本位 | 例 |
|---|---|---|
| 规则集内容更新 | patch | v0.1.0 → v0.1.1 |
| 模板分流逻辑变更 | minor | v0.1.1 → v0.6.0 |
| 架构破坏性变更 | major | v0.6.0 → v1.0.0 |

## CDN 缓存

jsDelivr 对 tag 的缓存是永久的（tag 不可变）。所以：

- 发布新版本 → 新 tag → 无缓存问题
- 修改已发布版本 → 不要，改 tag 会导致缓存不一致

发布后必跑验证：

```sh
for f in site/*.mrs; do
  local_hash=$(sha256sum "$f" | cut -d' ' -f1)
  remote_hash=$(curl -s "https://cdn.jsdelivr.net/gh/CauriumX/mihomo-apply@v0.1.0/$f" | sha256sum | cut -d' ' -f1)
  [ "$local_hash" != "$remote_hash" ] && echo "MISMATCH: $f"
done
```

## License

MIT
