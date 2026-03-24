# BashClaw V1 实施文档（含第二大脑 / MCP 知识库流程）
## 目标：分级执行、证据优先、知识优先、有限仲裁、全过程可追溯

> **给人看的大白话说明（LLM 可忽略本段）**  
> 这个系统可以理解成一个“会先翻笔记、再动手做事”的编程工作流。  
> 平时的小任务，就像普通作业，先让一个很强的助手直接做，做完马上跑测试、检查格式、看有没有报错，没问题就交付。  
> 稍微重要一点的任务，就像考试卷子，会先去翻“以前老师怎么批过类似题、哪里最容易丢分”的笔记本；如果笔记里已经有很像的经验和坑，就先照着避坑再做，这样很多任务可能就不用再花大价钱找第二个老师复查。  
> 如果还是比较重要，就像大考，会多找一个老师复查：第一个助手先做，第二个助手专门挑毛病。如果只是小毛病，改完再检查一下就行；如果是大问题，就必须再复查一次。  
> 特别重要或者两边吵不拢的任务，就像要请校长来裁决：前面两个助手把各自证据拿出来，OpenClaw 只负责判断该听谁的、还缺什么，不默认自己下场重写。  
> 最关键的是：每次最终形成的决定、踩过的坑、为什么这么做，都会回写到“第二大脑 / 知识库”里。这样这个系统会越用越聪明，类似问题以后先查旧经验，很多时候就不用反复触发 review 了，也更省 token。  
> 整个过程还会自动把关键进展记到 GitHub issue 里，这样人随时可以打开看：现在做到哪一步了、为什么这么改、谁提出了什么问题、最后为什么这么定。以后继续开发，也能直接顺着 issue 历史往下接。  
> 这个系统的核心思想不是“让很多模型一直开会”，而是“默认快，重要时再加审查，先查知识库，再决定要不要升级，而且全过程有记录”。

---

# 1. 文档目标

将 BashClaw 从“单一执行引擎”升级为“按风险分级 + 知识驱动的执行系统”，实现以下目标：

1. **默认快速执行**  
   绝大多数普通任务不进入多模型协商流程。

2. **知识优先于重复试错**  
   在 Review / Critical 任务开始前，优先检索第二大脑 / 知识库中是否已有类似决策、历史坑点、已验证方案。

3. **验证优先于主观判断**  
   优先依赖测试、lint、typecheck、repro、静态检查等硬证据，而不是模型自报置信度。

4. **分歧处理有上限**  
   不允许无限 review / rewrite 循环。

5. **高风险任务有更强治理**  
   只有在中高风险、知识不足、验证不足或明确 unresolved conflict 时，才启用 reviewer 或 OpenClaw 仲裁。

6. **全过程可审计、可追溯、可学习**  
   同时沉淀结构化日志、GitHub issue 阶段性记录与第二大脑知识回写，方便人工审核与后续迭代。

---

# 2. 设计原则

## 2.1 默认快
- 普通任务优先走 Tier 1。
- 只有在风险较高、改动较大、知识不足、验证不足或用户显式要求时，才升级到 Tier 2 / Tier 3。

## 2.2 知识优先
- 对需要 `/review` 或 `/critical` 的任务，先进行第二大脑检索。
- 若知识库中已有高相似度、可复用、已验证的历史决策，应优先复用这些经验。
- 能被知识复用消解的不确定性，不要反复消耗 reviewer token。

## 2.3 证据优先
- 验证结果比自报置信度更重要。
- Review 必须引用代码位置、验证缺口、测试证据、风险依据。
- 第二大脑命中结果只能作为参考证据，不能替代当前任务的验证。

## 2.4 分工明确
- Executor 负责实现。
- Reviewer 负责发现问题。
- Arbitrator 负责裁决。
- Knowledge Gate 负责检索历史经验与坑点。
- Memory Writer 负责把最终结论回写到第二大脑。
- 默认不让仲裁者直接变成第三个 coder。

## 2.5 有限循环
- Minor 问题修完即交付。
- Major 问题允许 second review。
- second review 后若仍 unresolved，再进入仲裁。

## 2.6 可追溯
- 每次运行输出结构化审计日志。
- 每个任务在 GitHub issue 里沉淀关键节点，而不是灌满原始对话噪声。
- 每次最终确定的决定与坑点，回写第二大脑，形成长期记忆。

---

# 3. 总体架构

BashClaw V1 采用三档执行模型，并在 Tier 2 / Tier 3 前增加 Knowledge Gate：

- **Tier 1：默认执行档**
- **Tier 2：Review 复核档**
- **Tier 3：Arbitration 仲裁档**
- **Knowledge Gate：第二大脑 / 知识库预检**
- **Memory Writeback：最终决策与坑点回写**

---

# 4. 总体主流程

## 4.1 默认任务（Tier 1）
用户请求  
→ Executor 执行  
→ repo-aware validation  
→ 通过则交付  
→ 写日志  
→ 如有价值可选回写知识库

## 4.2 Review / Critical 任务（Tier 2 / Tier 3）
用户请求  
→ 风险分类  
→ **Knowledge Gate：检索第二大脑相似决策 / 历史坑点 / 最佳实践**
→ 生成开发前知识摘要  
→ Executor 执行  
→ repo-aware validation  
→ Reviewer / Arbitrator  
→ 形成最终一致结论  
→ 交付  
→ **Memory Writeback：把决定、坑点、适用条件、回避条件写入第二大脑**
→ GitHub issue 记录关键节点  
→ 写审计日志

---

# 5. Tier 1 / Tier 2 / Tier 3 定义

## 5.1 Tier 1：默认执行档

### 适用场景
- 小型 bugfix
- 简单脚本
- docs 修改
- 小范围重构
- 低风险配置调整
- 日常非关键任务

### 流程
1. Executor 执行任务
2. 根据仓库实际变更触发 repo-aware validation
3. 验证通过则直接交付
4. 验证失败则返回失败结果，不自动升级仲裁
5. 若命中“高学习价值”规则，可选回写第二大脑

### 特点
- 速度最快
- 适合作为默认路径
- 不引入额外 reviewer 成本

---

## 5.2 Tier 2：Review 复核档

### 适用场景
- 中等风险任务
- 多文件改动
- 公共接口变更
- 新增依赖
- 用户显式使用 `/review`
- 自动风险分类命中 Tier 2

### 流程
1. Knowledge Gate 检索第二大脑
2. Executor 执行
3. 运行 repo-aware validation
4. 判断是否满足 skip-review 条件
5. 若满足则直接交付
6. 若不满足则进入 Reviewer
7. Reviewer 返回 `PASS / FAIL_MINOR / FAIL_MAJOR`
8. 按 verdict 进入对应后续路径
9. 最终一致结论写回第二大脑

### 特点
- 在成本和质量之间做平衡
- 不是所有任务默认进入
- Reviewer 只看证据，不做泛泛而谈
- 借助历史知识，尽量减少不必要 review

---

## 5.3 Tier 3：Arbitration 仲裁档

### 适用场景
- 权限、认证、token、secret
- 支付、计费
- deploy、prod、schema、migration
- second review 后仍 unresolved
- reviewer 与 validation 结论强冲突
- 用户显式使用 `/critical`

### 流程
1. Knowledge Gate 先检索第二大脑
2. 先完成 Tier 2 前置流程
3. 若 unresolved，则调用 OpenClaw 进行仲裁
4. OpenClaw 输出裁决和 required actions
5. Executor 按要求修改
6. 再次验证
7. 验证通过后交付
8. 仲裁结论、坑点与边界条件写回第二大脑

### 特点
- 只处理真正高风险和难收敛问题
- 默认低频触发
- 仲裁者默认不直接写代码
- 高价值结论必须回写知识库，避免未来重复消耗

---

# 6. Knowledge Gate：第二大脑 / MCP 知识库预检

## 6.1 目标
在开发前先回答以下问题：

1. 第二大脑里是否已有类似问题的历史决策？
2. 是否已有明确记录的坑点、失败案例、禁忌改法？
3. 是否已有推荐方案、适用条件、边界条件？
4. 这次任务是否足够相似到可以降低 review 强度？

## 6.2 适用范围
默认对以下任务启用：
- 所有 `/review`
- 所有 `/critical`
- 自动升 Tier 2 / Tier 3 的任务

可选扩展：
- 特定 Tier 1 任务也可启用检索，例如：
  - 高频重复型任务
  - 历史返工率高的目录
  - 过去踩坑频繁的模块

## 6.3 检索输入
Knowledge Gate 使用以下输入查询第二大脑：

- 用户原始需求
- 任务标题 / 摘要
- 涉及文件路径
- changeType
- risk_tags
- diff 初步意图（若已有）
- 模块关键词
- 技术栈关键词
- 错误信息 / 症状 / 目标行为

## 6.4 检索输出
Knowledge Gate 输出统一结构：

```text
KNOWLEDGE_PRECHECK:
- similar_decisions:
  - [id] 标题 / 摘要 / 相似原因
- known_pitfalls:
  - 坑点 1
  - 坑点 2
- recommended_patterns:
  - 推荐方案 1
  - 推荐方案 2
- constraints:
  - 必须遵守的边界
- confidence:
  - low / medium / high
- action_hint:
  - proceed
  - proceed_with_caution
  - require_review
  - require_critical
```

## 6.5 作用方式
Knowledge Gate 的结果会被送入：
- Executor 作为“开发前注意事项”
- Reviewer 作为“历史风险参照”
- Arbitrator 作为“历史决策背景”
- Issue Trace 作为 `KNOWLEDGE_PRECHECK` 节点
- 审计日志作为 `knowledge_hits` / `knowledge_confidence`

## 6.6 重要边界
- 知识库命中 **不能直接替代当前验证**
- 历史决策只能降低不确定性，不能跳过必要测试
- 只有当“知识高相似 + 当前改动低风险 + 当前验证充分”同时满足时，才允许减少 review 触发概率

---

# 7. Memory Writeback：决策与坑点回写

## 7.1 目标
让第二大脑越用越聪明，未来遇到类似问题时优先复用历史经验，而不是反复触发 review / arbitration。

## 7.2 默认回写时机
以下节点完成后，触发回写：

1. Tier 2 最终 `PASS`
2. Tier 3 仲裁完成且交付
3. 发现明确、可复用的“坑点 / 反模式”
4. 发现“某类改动不应 skip review”的经验规则
5. 出现一次高价值失败案例（即使未成功交付，也可回写失败经验）

## 7.3 回写内容
每条知识至少包含：

- decision_title
- task_summary
- applicable_scope
- non_applicable_scope
- final_decision
- reasons
- known_pitfalls
- validation_evidence
- review_or_arbitration_needed
- risk_tags
- changeType
- repo_or_module_context
- linked_issue
- linked_pr
- timestamp

## 7.4 回写格式建议
```text
MEMORY_WRITEBACK:
- title: 刷新 token 时必须校验租户边界
- context: auth/session.py 刷新逻辑
- decision: 不允许仅按 user_id 查询
- why:
  - 存在跨租户污染风险
- pitfalls:
  - 只覆盖 happy path 测试会漏掉非法 token 场景
- required_validation:
  - token invalid case
  - tenant boundary case
- future_hint:
  - 同类 auth/session 修改默认升 Tier 3
```

## 7.5 去重与合并
回写前应进行去重：
- 若第二大脑已有高相似条目，则执行 merge/update，而不是重复新增
- 若是同一主题的新坑点，可追加到现有知识条目
- 若是旧决策被推翻，必须标记 superseded / replaced_by

---

# 8. 知识驱动的降 review 机制

## 8.1 目标
减少不必要的 review token 消耗，但不能牺牲安全性。

## 8.2 降 review 的必要条件
只有当以下条件同时满足时，才允许“知识辅助降 review”：

1. Knowledge Gate 命中高相似历史决策
2. 历史条目具有明确验证证据
3. 当前 changeType 属于低风险
4. 当前风险分类未命中高风险模式
5. 当前 repo-aware validation 全通过
6. 当前改动规模较小
7. 当前任务不涉及 auth / deploy / schema / migration 等关键域

## 8.3 规则
- 知识命中可以帮助 **减少 review 触发概率**
- 不能帮助 **跳过必要验证**
- 对高风险域，知识命中只能帮助“少走弯路”，不能直接降到 Tier 1

---

# 9. 手动触发与自动升级

## 9.1 手动触发
- 无前缀：Tier 1
- `/review xxx`：Tier 2
- `/critical xxx`：Tier 3

优先级：

`/critical` > `/review` > 自动升级 > 默认 Tier 1

## 9.2 自动升级规则
自动升级由两层组成：

### 第一层：路径 / 关键词规则
#### 自动升 Tier 2
命中以下任一条件：
- 修改文件数 > 2
- diff 行数超过阈值
- 涉及公共接口变更
- 新增依赖
- 删除核心逻辑
- 命中以下路径或关键词：
  - `api`
  - `service`
  - `core`
  - `shared`

#### 自动升 Tier 3
命中以下路径或关键词：
- `auth`
- `permission`
- `oauth`
- `token`
- `secret`
- `payment`
- `billing`
- `deploy`
- `migration`
- `schema`
- `prod`
- `acl`

### 第二层：diff 内容模式分析
`risk_classifier.sh` 需要检查 diff 内容中是否存在以下模式：

- 认证与会话：
  - token / jwt / refresh / session / cookie
- 权限与租户边界：
  - role / permission / acl / tenant / scope
- 密钥与配置：
  - secret / api_key / private_key / credential / env
- 数据库变更：
  - migration / alter table / drop column / schema / index
- 生产与部署：
  - deploy / rollout / helm / docker / prod / release
- 外部写操作：
  - payment / billing / charge / refund
- 风险性系统调用：
  - shell exec / subprocess / ssh / remote call

### 规则
- 第一层或第二层任一命中高风险，都可提升档位
- 第二层优先级高于第一层
- 允许命中多个 `risk_tags`

---

# 10. changeType 分类

V1 引入 `changeType`，作为 skip-review 与风险分类的重要依据。

## 10.1 changeType 枚举
- `docs_only`
- `comment_only`
- `test_only`
- `logic_change`
- `config_change`
- `schema_change`
- `infra_change`
- `mixed_change`

## 10.2 默认判断原则

### 可视为低风险倾向
- `docs_only`
- `comment_only`
- `test_only`

### 默认不应轻易 skip review
- `config_change`
- `schema_change`
- `infra_change`
- `logic_change`
- `mixed_change`

---

# 11. Skip Review 规则

Tier 2 中，只有在满足以下**全部条件**时，才允许跳过 Reviewer：

1. 所有验证通过
2. 修改文件数 ≤ 2
3. diff 行数 ≤ 阈值
4. 未命中高风险路径或高风险 diff 模式
5. 未新增依赖
6. 未涉及 auth / deploy / schema / migration
7. `changeType` 属于：
   - `docs_only`
   - `comment_only`
   - `test_only`
8. Executor 的 `CONFIDENCE` 仅作弱辅助信号，不能单独放行
9. 若启用知识降 review，则必须满足第 8 节全部条件

## 11.1 建议默认阈值
- `maxChangedFilesForSkip = 2`
- `maxDiffLinesForSkip = 80`

## 11.2 特别说明
即使变更极小，只要 `changeType` 属于：
- `config_change`
- `schema_change`
- `infra_change`
- `logic_change`
- `mixed_change`

则默认**不允许**用“变更小”作为唯一理由跳过 review。

---

# 12. Repo-aware Validation

V1 不再使用“响应中包含代码就触发验证”的方式。  
验证必须基于仓库实际变更来决定。

## 12.1 验证输入
验证器依赖以下输入：

1. `git diff --name-only`
2. 变更文件类型
3. 项目配置文件
4. 仓库已有命令入口
5. 用户提供的复现步骤

## 12.2 验证命令优先级

### Python
- `pytest`
- `ruff`
- `mypy`
- `pyproject.toml` 中脚本
- `Makefile`
- `justfile`

### JS / TS
- `npm test`
- `pnpm test`
- `yarn test`
- `eslint`
- `tsc --noEmit`

### Shell
- `shellcheck`

### Docker / CI / YAML
- parse / lint / dry-run 检查

### SQL / migration
- migration validate
- schema diff check
- dry-run

### Docs-only
- 默认不跑重测试
- 可选格式检查

## 12.3 验证结果分类
- `PASS`
- `FAIL_TEST`
- `FAIL_LINT`
- `FAIL_TYPECHECK`
- `FAIL_REPRO`
- `FAIL_VALIDATE`
- `NO_VALIDATOR_FOUND`

### 规则
- `NO_VALIDATOR_FOUND` 不等于 `PASS`
- 必须写入审计日志
- 可作为 reviewer 评估“验证覆盖是否充分”的依据

---

# 13. Tier 2 详细流程

## 13.1 Phase A：Knowledge Precheck
在 Executor 之前先做 Knowledge Gate。

### 输出示例
```text
KNOWLEDGE_PRECHECK:
- similar_decisions:
  - KB-102 auth/session 刷新逻辑
- known_pitfalls:
  - 只按 user_id 查询会漏租户边界
- recommended_patterns:
  - 必须增加 invalid token + tenant boundary case
- confidence: high
- action_hint: require_review
```

## 13.2 Phase B：Executor 执行
Executor 负责：
- 理解需求
- 参考知识预检结果
- 修改代码
- 输出变更摘要
- 输出可选 `CONFIDENCE`
- 触发 repo-aware validation

### 输出结构建议
```text
SUMMARY:
- 做了什么
- 改了哪些文件
- 为什么这样改
- 参考了哪些知识条目

CONFIDENCE: 82

VALIDATION:
- pytest: PASS
- ruff: PASS
- repro: PASS
```

## 13.3 Phase C：Skip Review 判定
若满足第 11 节所有条件：
- 直接交付
- 写入日志：`review_skipped=true`

否则进入 Reviewer。

## 13.4 Phase D：Reviewer 评审

### Reviewer 输入
- 用户原始需求
- **匿名 patch / diff**
- 验证结果
- 变更摘要
- 风险标签
- changeType
- 知识预检摘要（不暴露模型身份）

### 匿名化要求
Reviewer prompt 中不得暴露：
- executor 模型名
- reviewer 模型名
- arbitrator 模型名
- “这是 Claude / Codex 的输出”等身份标签

允许使用中性标签：
- `Patch A`
- `Validation Output`
- `Knowledge Notes`
- `Review Context`

### Reviewer 只回答四类问题
1. 验证覆盖是否充分
2. 实现是否偏离需求
3. 是否存在明确风险
4. 最终 verdict

### Verdict 枚举
- `PASS`
- `FAIL_MINOR`
- `FAIL_MAJOR`

### Reviewer 约束
- 必须引用具体文件、位置、缺失测试或证据
- 不允许写“感觉不好”“建议优化一下”这类空话
- 不默认给整套替代实现
- 重点评估正确性、覆盖与风险

### 输出格式建议
```text
VERDICT: FAIL_MAJOR

ISSUES:
1. auth/session.py:84
   问题：刷新 token 时未校验租户边界
   证据：当前逻辑仅按 user_id 查询
   风险：跨租户会话污染

2. tests/test_auth_refresh.py
   问题：缺少非法 token 场景
   证据：仅覆盖 happy path
```

## 13.5 Phase E：修复策略

### 若 `PASS`
- 直接交付

### 若 `FAIL_MINOR`
- Executor 根据 issue list 定向修复
- 再跑验证
- 不进入 second review
- 验证通过即可交付

### 若 `FAIL_MAJOR`
- Executor 根据 issue list 定向修复
- 再跑验证
- 必须进入 second review

## 13.6 Phase F：Second Review

second review 不应只允许 `PASS / FAIL_MAJOR`，还应允许降级结果。

### 输出允许值
- `PASS`
- `FAIL_MINOR`
- `FAIL_MAJOR`

### Reviewer 在 second review 只检查
1. 上一轮 major 问题是否被解决
2. 是否引入新的高风险问题
3. 当前问题是否已从 Major 降级为 Minor

---

# 14. 轻量级收敛检测

V1 不采用复杂语义相似度算法，而采用可解释的规则型收敛判断。

## 14.1 convergence_state 枚举
- `RESOLVED`
- `DOWNGRADED`
- `STALLED`
- `DIVERGED`

## 14.2 判定规则

### `RESOLVED`
- second review = `PASS`

### `DOWNGRADED`
- first review = `FAIL_MAJOR`
- second review = `FAIL_MINOR`

说明：问题显著收敛，但尚有轻微问题。  
处理方式：不进入 Tier 3，按 Minor 路径修复并交付。

### `STALLED`
- first review = `FAIL_MAJOR`
- second review = `FAIL_MAJOR`
- issue 数量减少，但核心问题仍未完全解决

说明：方向在变好，但未真正收敛。  
处理方式：可升级 Tier 3。

### `DIVERGED`
- second review 仍 `FAIL_MAJOR`
- 且出现新增重大问题、风险扩大、或需求理解冲突升级

说明：讨论越改越乱。  
处理方式：直接升级 Tier 3。

---

# 15. Tier 3 仲裁流程

## 15.1 触发条件
满足任一条件即可触发：

1. second review 后仍 unresolved
2. `convergence_state = STALLED`
3. `convergence_state = DIVERGED`
4. 验证通过但 reviewer 明确指出高风险缺陷
5. 验证失败但 reviewer 认为实现方向正确
6. Executor 与 Reviewer 对需求理解发生根本冲突
7. 用户显式使用 `/critical`

## 15.2 OpenClaw 角色定义
OpenClaw 在 V1 中默认是：
- 仲裁者
- 决策解释器
- required actions 生成者

默认**不是**：
- 第三个 coder
- 默认 patch author

## 15.3 OpenClaw 输入
- 用户原始需求
- Executor patch / 摘要
- Reviewer 的 issue list
- 所有验证结果
- first review / second review 结果
- risk_tags
- changeType
- convergence_state
- Knowledge Gate 摘要

## 15.4 OpenClaw 输出格式

```text
ARBITRATION_DECISION:
- adopt_executor
- adopt_reviewer
- revise_executor_with_constraints

RATIONALE:
- 为什么这样判
- 哪些证据最关键
- 哪些意见不成立

REQUIRED_ACTIONS:
1. 补哪些测试
2. 改哪些逻辑
3. 清除哪些风险
```

## 15.5 落地规则
默认落地方式：
- OpenClaw 不直接改代码
- Executor 按 `REQUIRED_ACTIONS` 实施修改
- 再次运行验证
- 验证通过后才交付

### 可选扩展开关
```json
{
  "allowArbitratorPatch": false
}
```

默认值：`false`

---

# 16. GitHub Issue Trace

V1 引入 GitHub issue 过程追踪，用于人工审核与后续协作延续。

## 16.1 目标
- 让人工随时打开 GitHub 查看当前任务状态
- 让后续开发者沿着历史 issue 继续推进
- 让 review / arbitration 判断链条可追溯
- 让知识预检与知识回写也有可见记录

## 16.2 原则
1. 沉淀关键决策，不沉淀全部原始对话
2. 一个任务绑定一个主 issue
3. 长任务可拆 sub-issues
4. 原始长日志应存到仓库 artifact 或 markdown 文件中
5. issue 中只记录阶段性摘要与决策节点

## 16.3 推荐记录节点
- `INTAKE`
- `KNOWLEDGE_PRECHECK`
- `PLAN`
- `EXECUTOR_RESULT`
- `VALIDATION_RESULT`
- `REVIEW_VERDICT`
- `ARBITRATION_DECISION`
- `MEMORY_WRITEBACK`
- `FINAL_DELIVERY`

## 16.4 comment 策略
推荐使用：
- **一条可更新 ledger comment**
- **少量关键节点追加 comment**

避免每一步都新增评论，降低噪声和通知压力。

## 16.5 建议输出模板

### KNOWLEDGE_PRECHECK
```text
## [KNOWLEDGE_PRECHECK]
- Query: token refresh + tenant boundary
- Hits:
  - KB-102
  - KB-118
- Known pitfalls:
  - 只按 user_id 查询
  - 缺 invalid token case
- Action hint: require_review
```

### PLAN
```text
## [PLAN]
- Task ID: ...
- Effective Tier: Tier 2
- Executor: claude
- Reviewer: codex
- Risk tags: auth, token
- Planned changes:
  - ...
  - ...
```

### MEMORY_WRITEBACK
```text
## [MEMORY_WRITEBACK]
- Status: merged
- Knowledge entry: KB-102
- Added pitfalls:
  - refresh path must validate tenant boundary
- Future hint:
  - auth/session changes should not skip review
```

## 16.6 实现建议
新增：
- `lib/issue_trace.sh`

职责：
- 绑定或创建 issue id
- 更新 ledger comment
- 在关键节点写 comment
- 附加 artifact 链接

---

# 17. 预算机制

V1 不做复杂美元计费，但引入**执行次数预算**，防止多模型流程被过度触发。

## 17.1 预算目标
- 防止 Tier 2 / Tier 3 被自动升级规则无限放大
- 对高成本路径设定日限额
- 在系统早期观察阶段，优先控制“触发频率”
- 通过第二大脑命中减少重复 review 消耗

## 17.2 建议预算字段
```json
{
  "budget": {
    "maxTier2RunsPerDay": 20,
    "maxTier3RunsPerDay": 3,
    "maxArbitrationsPerTask": 1,
    "warnOnDailyTier3Overflow": true
  }
}
```

## 17.3 默认策略
- Tier 2 到达日预算上限时，只允许显式 `/review` 继续触发
- Tier 3 到达日预算上限时，只允许显式 `/critical` 继续触发
- 单任务最多仲裁一次
- 超预算必须写入日志与 GitHub trace

---

# 18. 路由与作用域控制

## 18.1 routing.sh 前缀解析
需要正确处理：
- 只有 `/review`
- `/review xxx`
- 只有 `/critical`
- `/critical xxx`

### 伪代码
```bash
local engine_override=""
local clean_message="$message"

case "$message" in
  "/critical")
    engine_override="arbitrated"
    clean_message=""
    ;;
  /critical\ *)
    engine_override="arbitrated"
    clean_message="${message#"/critical "}"
    ;;
  "/review")
    engine_override="reviewed"
    clean_message=""
    ;;
  /review\ *)
    engine_override="reviewed"
    clean_message="${message#"/review "}"
    ;;
esac
```

## 18.2 `BASHCLAW_ENGINE_OVERRIDE` 作用域
`BASHCLAW_ENGINE_OVERRIDE` 只允许在**单次 dispatch** 内生效。

要求：
- 设置前保存旧值
- 请求结束后恢复或 unset
- 禁止跨轮污染

### 伪代码
```bash
local prev_override="${BASHCLAW_ENGINE_OVERRIDE:-}"
export BASHCLAW_ENGINE_OVERRIDE="$engine_override"

# ... dispatch ...

if [[ -n "$prev_override" ]]; then
  export BASHCLAW_ENGINE_OVERRIDE="$prev_override"
else
  unset BASHCLAW_ENGINE_OVERRIDE
fi
```

---

# 19. 文件改动方案

## 19.1 新增文件
- `lib/engine_codex.sh`
- `lib/engine_reviewed.sh`
- `lib/engine_arbitrated.sh`
- `lib/validator_repo.sh`
- `lib/risk_classifier.sh`
- `lib/knowledge_gate.sh`
- `lib/memory_writeback.sh`
- `lib/audit_log.sh`
- `lib/issue_trace.sh`

## 19.2 修改文件
- `lib/routing.sh`
- `lib/engine.sh`
- `bashclaw.json`

---

# 20. 配置示例

```json
{
  "agents": {
    "defaults": {
      "engine": "claude",
      "review": {
        "executor": "claude",
        "reviewer": "codex",
        "arbitrator": "openclaw",
        "confidenceWeight": "low",
        "maxChangedFilesForSkip": 2,
        "maxDiffLinesForSkip": 80,
        "allowSecondReview": true,
        "allowArbitratorPatch": false
      },
      "risk": {
        "autoTier2Keywords": ["api", "service", "core", "shared"],
        "autoTier3Keywords": [
          "auth", "permission", "oauth", "token", "secret",
          "payment", "billing", "deploy", "migration",
          "schema", "prod", "acl"
        ],
        "enableDiffPatternRisk": true
      },
      "knowledge": {
        "enabled": true,
        "provider": "mcp",
        "precheckTiers": ["reviewed", "arbitrated"],
        "retrieveTopK": 5,
        "minSimilarity": 0.75,
        "allowKnowledgeAssistedSkip": true,
        "writebackOn": [
          "review_pass",
          "arbitration_decision",
          "final_delivery",
          "high_value_failure"
        ],
        "dedupeBeforeWrite": true,
        "mergeOnSimilarEntry": true
      },
      "validation": {
        "enableRepoAwareValidation": true,
        "treatNoValidatorFoundAsPass": false
      },
      "issueTrace": {
        "enabled": true,
        "mode": "milestones_only",
        "updateLedgerComment": true,
        "attachArtifacts": true,
        "maxCommentsPerRun": 8
      },
      "budget": {
        "maxTier2RunsPerDay": 20,
        "maxTier3RunsPerDay": 3,
        "maxArbitrationsPerTask": 1,
        "warnOnDailyTier3Overflow": true
      }
    }
  }
}
```

---

# 21. 审计日志格式

每次执行输出结构化 JSON 记录。

## 21.1 建议字段
```json
{
  "task_id": "20260324-abc123",
  "tier_requested": "reviewed",
  "tier_effective": "arbitrated",
  "executor": "claude",
  "reviewer": "codex",
  "arbitrator": "openclaw",
  "changed_files": 4,
  "diff_lines": 126,
  "change_type": "logic_change",
  "risk_tags": ["auth", "token"],
  "knowledge_hits": ["KB-102", "KB-118"],
  "knowledge_confidence": "high",
  "knowledge_action_hint": "require_review",
  "knowledge_writeback_status": "merged",
  "validation": [
    {"name": "pytest", "status": "PASS"},
    {"name": "ruff", "status": "PASS"},
    {"name": "repro", "status": "FAIL"}
  ],
  "review_skipped": false,
  "review_verdict_1": "FAIL_MAJOR",
  "review_verdict_2": "FAIL_MINOR",
  "convergence_state": "DOWNGRADED",
  "issue_trace_id": 27,
  "tier_budget_bucket": "tier2",
  "arbitration_decision": null,
  "final_status": "DELIVERED"
}
```

---

# 22. 实施步骤

## Phase 1：基础接线
1. 验证 Codex CLI 可用性
2. 新建 `engine_codex.sh`
3. 修改 `engine.sh` 支持 `reviewed` / `arbitrated`
4. 修改 `routing.sh` 增加前缀解析与 override 作用域恢复

## Phase 2：验证与风控
5. 新建 `validator_repo.sh`
6. 新建 `risk_classifier.sh`
7. 实现路径 + diff 内容双层风险分类
8. 实现 `changeType` 分类
9. 实现 skip-review 客观判定

## Phase 3：知识库接入
10. 新建 `knowledge_gate.sh`
11. 接入 MCP 检索第二大脑
12. 设计知识预检统一输出格式
13. 实现知识命中去重与置信分级
14. 把知识摘要注入 Executor / Reviewer / Arbitrator 输入

## Phase 4：Tier 2 编排
15. 新建 `engine_reviewed.sh`
16. 实现 PASS / FAIL_MINOR / FAIL_MAJOR 流程
17. 接入匿名 review prompt
18. 实现 second review
19. 实现轻量级收敛检测

## Phase 5：Tier 3 编排
20. 新建 `engine_arbitrated.sh`
21. 接入 OpenClaw agent_message
22. 实现 arbitration input/output schema
23. 实现“仲裁后由 Executor 落地”

## Phase 6：追踪与日志
24. 新建 `audit_log.sh`
25. 新建 `issue_trace.sh`
26. 全 tier 接入 JSON 审计日志
27. 全 tier 接入 GitHub issue milestones trace

## Phase 7：知识回写
28. 新建 `memory_writeback.sh`
29. 实现决策 / 坑点 / 失败经验的结构化回写
30. 实现相似条目 merge/update
31. 在 final delivery / arbitration / high-value failure 后触发回写

## Phase 8：预算与回归
32. 实现 Tier 2 / Tier 3 次数预算
33. 做端到端回归测试
34. 建立首批基线指标

---

# 23. 测试计划

## 23.1 Tier 1
场景：
- docs-only 修改
- 小脚本修改
- 小 bugfix

检查：
- 默认行为是否保持轻量
- repo-aware validator 是否正确触发
- `NO_VALIDATOR_FOUND` 是否被记录

## 23.2 Knowledge Gate
场景：
- review 任务命中相似历史决策
- critical 任务命中历史坑点
- 未命中任何知识条目
- 命中旧决策但当前场景不适用

检查：
- 检索是否输出统一格式
- 知识摘要是否正确注入后续 prompt
- 不适用历史知识是否被正确降权
- 是否不会用历史知识替代当前验证

## 23.3 Tier 2
场景：
- 满足 skip-review 条件的小改动
- 中等改动应触发 review
- `FAIL_MINOR`
- `FAIL_MAJOR`
- `FAIL_MAJOR -> FAIL_MINOR`

检查：
- skip 只由客观条件决定
- 匿名化 reviewer prompt 是否生效
- second review 是否允许降级
- convergence_state 是否正确输出

## 23.4 Tier 3
场景：
- auth 相关变更
- migration 相关变更
- second review unresolved
- reviewer 与 validation 结论冲突

检查：
- Tier 3 是否低频触发
- OpenClaw 默认不直接写代码
- 仲裁后是否仍需 re-validate

## 23.5 Memory Writeback
场景：
- review 通过后写回成功
- arbitration 后写回成功
- 高相似条目触发 merge
- 旧知识被新决策替换

检查：
- 是否正确去重
- 是否保留适用范围与不适用范围
- 是否能回写坑点与验证证据
- 是否能在下次任务被正确命中

## 23.6 Issue Trace
场景：
- 正常 Tier 1 跑完
- Tier 2 进入 review
- Tier 3 进入仲裁
- 知识预检 / 知识回写
- 超预算任务

检查：
- 是否只记录关键节点
- ledger comment 是否能正确更新
- artifact 链接是否可用
- 噪声是否受控

---

# 24. 成功标准

上线后，V1 至少应能回答以下问题：

1. Tier 1 / Tier 2 / Tier 3 占比各是多少
2. review skip 比例是多少
3. skip 后返工率是多少
4. `FAIL_MINOR / FAIL_MAJOR` 分布如何
5. `DOWNGRADED / STALLED / DIVERGED` 比例如何
6. 哪类目录或 diff 模式最容易升 Tier 3
7. 哪种 changeType 最容易出问题
8. 哪个验证器最常失败
9. OpenClaw 仲裁是否真正减少返工
10. 第二大脑命中率是多少
11. 第二大脑命中后 review 触发率是否下降
12. 哪类知识条目最能减少 reviewer token 消耗
13. 哪类知识条目最容易过时或误导
14. GitHub issue trace 是否提高人工接管效率

---

# 25. 非目标

V1 不追求以下目标：

- 不让所有任务都进入三方会审
- 不做无限 review 循环
- 不把 executor 自报置信度当成主决策依据
- 不默认让 OpenClaw 成为第三个 coder
- 不把“响应里有代码块”当作验证触发条件
- 不在 V1 内做复杂 token / 美元成本核算
- 不把所有内部原始对话全量同步进 GitHub issue
- 不让第二大脑替代当前任务的验证与审查

---

# 26. 推荐默认策略

最务实的默认行为：

- **Tier 1**：尽可能快，靠 repo-aware validation 守住底线
- **Tier 2**：先查第二大脑，再决定是否需要 Reviewer
- **Tier 3**：只在 unresolved major conflict 时上 OpenClaw
- **Knowledge Gate**：默认对 review / critical 任务启用
- **Memory Writeback**：最终一致结论必须回写高价值经验
- **Issue Trace**：只记关键节点，不记全部噪声
- **预算**：先控升级次数，再谈精细成本
- **日志**：先做全，后面才能调优
