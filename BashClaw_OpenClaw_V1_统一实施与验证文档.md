# BashClaw / OpenClaw V1 统一实施与验证文档
## 目标：知识优先、证据裁决、有限升级、闭环学习、可验证有效

> **给人看的大白话说明（LLM 可忽略本段）**  
> 这套系统可以理解成一个“先翻旧笔记、再做题、做不准再找老师、最后把新经验记回笔记本”的编程工作流。  
> 平时的小任务，先让一个很强的助手直接做，做完马上跑测试、检查格式、看有没有报错，没问题就交付。  
> 稍微重要一点的任务，不是立刻找第二个模型来回开会，而是先去查“第二大脑 / 知识库”：以前有没有做过类似问题？哪里最容易踩坑？以前已经验证过的方案是什么？如果知识库里已经有很像的经验，这次就优先照着避坑，很多问题可能根本不需要再花很多 token 做 review。  
> 如果还是不放心，就让第二个助手来复查。但这个复查不能只说“我觉得有问题”，必须给出证据：哪一行、什么风险、怎么验证、什么结果算问题成立。然后系统会优先用测试、静态检查、定向验证、历史知识这些“硬证据”来裁决，而不是靠第三个模型装法官。  
> 如果问题还是说不清，比如需求本身有歧义，或者当前确实无法验证，就再升级给人来拍板。人类的决定不会白做，会被写回第二大脑，让下次类似问题更容易自动处理。  
> 同时，关键过程还会写到 GitHub issue 里：做到了哪一步、查到了哪些历史经验、为什么最后这样决定、哪些坑以后要避免。这样以后继续开发的人可以直接沿着历史往下接。  
> 这套系统的核心不是“让很多模型一直争论”，而是“默认快，先查知识，再用证据裁决，只有真的不确定时才升级，而且每次升级都变成未来的知识”。如果做得好，这个系统会越来越省 token，也越来越少需要高成本 review。

---

# 1. 文档目的

本文档给出一套可同时适配 **BashClaw** 与 **OpenClaw** 的统一架构与验证方案，目标不是描述“理想中的智能系统”，而是建立一套：

1. **可以真实落地的执行框架**
2. **可以被实验验证是否有效的评测方法**
3. **可以明确验收是否通过的标准体系**

本文档要解决的不是单一工程问题，而是三个核心问题：

## 1.1 目标一：闭环学习是否真的成立
也就是：

- 系统是否会随着第二大脑 / 知识库的积累，越来越少触发高成本 review / critical
- 在质量不下降的前提下，是否能显著降低 token 成本、重复劳动和人工兜底次数

## 1.2 目标二：复杂问题解决能力是否真的增强
也就是：

- 原本单模型难以解决的问题，是否能通过“知识预检 + 证据驱动裁决 + 有限升级 + 记忆回写”得到明显更高的 solve rate

## 1.3 目标三：这套系统是否值得继续演化
也就是：

- 提升到底来自哪一层：知识库？review？证据裁决？人工兜底？
- 这套系统是否优于“简单多轮讨论”或“同模型假装仲裁者”的方案

---

# 2. 设计结论（先给结论）

在只有 **Opus 4.6** 和 **Codex** 两个模型可用的现实约束下，本文档明确放弃以下思路：

- 不把“prompt 换个角色”视为真正的第三个仲裁模型
- 不把多轮模型辩论当成核心能力来源
- 不把“更多上下文、更长讨论”当成必然更聪明
- 不让模型口头判断凌驾于验证器和证据之上

本文档采用的核心设计是：

## 2.1 统一架构原则
**Knowledge Gate + Executor + Reviewer + Evidence-Driven Resolution + Human Escalation + Memory Writeback**

也就是：

1. 先查第二大脑 / 知识库
2. 再执行
3. 再审查
4. 审查结果优先转成“可验证主张”
5. 由验证器、定向测试、静态规则和历史知识来裁决
6. 只有真正无法验证或需求冲突时才升级给人
7. 人的决策要写回知识库，形成长期闭环学习

## 2.2 这不是“第三模型仲裁”
而是：

**证据驱动裁决协议（Evidence-Driven Resolution Protocol）**

它不依赖一个“更聪明的第三模型”，而依赖：

- 两个不同能力侧重的模型
- 一组硬验证器
- 一套结构化裁决协议
- 一个持续积累的第二大脑
- 人类作为真正的最终兜底者

---

# 3. 适用范围：BashClaw 与 OpenClaw 的统一方式

本文档中的核心逻辑是**平台无关**的：

- **BashClaw**：更偏命令行执行编排、引擎切换、repo 内工作流
- **OpenClaw**：更偏 Agent 协作、技能调用、长链任务、外部系统协调

但二者共享同一套核心状态机与决策逻辑：

- 风险分类
- Knowledge Gate
- repo-aware validation
- review 触发策略
- 证据驱动裁决协议
- human escalation
- memory writeback
- issue trace
- 审计与评测指标

## 3.1 对 BashClaw 的主要体现
- 本地仓库开发与修复
- shell / git / 测试 / lint / typecheck 驱动
- reviewed / critical 两类升级工作流
- 更强调 repo-aware validator 和 targeted validation

## 3.2 对 OpenClaw 的主要体现
- Agent 间角色协调
- 知识库检索、长链任务上下文管理
- 任务分解、外部系统调用、跨任务记忆复用
- 更强调 Knowledge Gate、Issue Trace、Memory Writeback 与多任务连续性

## 3.3 共用的核心
不管是 BashClaw 还是 OpenClaw，都必须遵守：

- 先查知识，再决定是否高成本 review
- reviewer 必须提出“可验证主张”
- 无法验证的问题才升级给人
- 人类决定必须回写知识库
- 所有过程都必须进入可审计日志体系

---

# 4. 核心设计原则

## 4.1 默认快
- 普通任务默认走最低成本路径
- 不是所有任务都需要 review / critical

## 4.2 知识优先
- 对 review / critical 任务，必须先查第二大脑
- 已有高相似、已验证的历史经验，应优先复用

## 4.3 证据优先
- 验证器、定向测试、静态分析、历史裁决 > 模型主观判断
- “我觉得有问题”不构成裁决依据

## 4.4 人类兜底，而不是模型伪装兜底
- 真正无法验证、需求歧义、业务约束冲突，必须升级给人
- 不再用同模型换 prompt 假装第三法官

## 4.5 记忆必须可用，而不是越堆越大
- 第二大脑必须提供少量、精准、任务相关的经验
- 不能把知识库当成无限上下文垃圾场

## 4.6 所有升级都要转化为未来的自动化能力
- 每次人工拍板都必须变成未来可复用的知识条目
- 否则系统永远不会变便宜

---

# 5. 统一系统总体架构

## 5.1 架构模块

- **Risk Classifier**：风险分类器
- **Knowledge Gate**：第二大脑 / 知识库预检
- **Executor**：执行器（Opus 或 Codex）
- **Base Validation**：基础验证器
- **Reviewer**：复查器（另一个模型）
- **Evidence-Driven Resolution**：证据驱动裁决协议
- **Human Escalation**：人工升级兜底
- **Memory Writeback**：知识回写
- **Issue Trace**：GitHub issue 阶段性留痕
- **Audit & Evaluation Layer**：审计与评测层

## 5.2 总体流程

```text
用户请求
→ 风险分类
→ Knowledge Gate
→ Executor
→ Base Validation
→ Reviewer（如需要）
→ Evidence-Driven Resolution
→ [若 unresolved] Human Escalation
→ 最终交付
→ Memory Writeback
→ Issue Trace
→ 审计日志
```

---

# 6. 三档任务分层（保留，但重新定义）

虽然本文档不再把“仲裁”理解为第三模型法官，但仍保留三档分层，因为它对资源控制与行为约束仍然很有价值。

## 6.1 Tier 1：默认执行档
适用：
- 小 bugfix
- docs / 注释 / 测试补充
- 低风险重构
- 明确、局部、可快速验证的任务

流程：
1. Executor
2. Base Validation
3. 通过则直接交付
4. 可选知识回写

特点：
- 最快
- 最省 token
- 不自动进入高成本 review

---

## 6.2 Tier 2：Review 档
适用：
- 中等风险任务
- 多文件修改
- 公共接口变更
- 历史上高返工率模块
- 用户显式 `/review`

流程：
1. Knowledge Gate
2. Executor
3. Base Validation
4. Reviewer
5. Evidence-Driven Resolution
6. 若全都可裁决，则自动收敛
7. 否则升级人工

特点：
- 不是“多模型讨论”，而是“第二模型提出可验证问题”
- 大部分争议应在证据层解决

---

## 6.3 Tier 3：Critical 档
适用：
- auth / permission / token / secret
- payment / billing
- deploy / prod / migration / schema
- 需求冲突
- 无法验证但风险很高的问题
- 用户显式 `/critical`

流程：
1. Knowledge Gate
2. Executor
3. Base Validation
4. Reviewer
5. Evidence-Driven Resolution
6. unresolved 或 requirement conflict 升级人工
7. 人类最终裁决
8. 必须回写第二大脑

特点：
- 不再是“调 OpenClaw 假装仲裁模型”
- 而是“高风险问题的人类决策与制度化回写”

---

# 7. Knowledge Gate：第二大脑 / MCP 知识库预检

## 7.1 目标
在真正开始开发或 review 前，回答：

1. 有没有类似问题的历史决策？
2. 有没有明确记录的坑点？
3. 有没有已验证、可复用的方案？
4. 当前任务与历史问题相似到什么程度？
5. 当前任务是否因此可以减少 review 触发概率？

## 7.2 强制启用范围
默认对以下任务启用：
- 所有 Tier 2
- 所有 Tier 3
- 指定高返工率目录
- 指定高风险模块

## 7.3 检索输入
Knowledge Gate 检索时应至少使用：

- 用户原始需求
- 任务摘要
- 文件路径 / 模块名
- changeType
- risk_tags
- 错误栈 / 症状 / 目标行为
- 技术栈关键词
- 历史 issue / PR 上下文（如有）

## 7.4 输出格式
```text
KNOWLEDGE_PRECHECK:
- similar_decisions:
  - [KB-102] 刷新 token 必须校验租户边界
- known_pitfalls:
  - 不要只按 user_id 查询
  - 不要只覆盖 happy path
- recommended_patterns:
  - 增加 invalid token case
  - 增加 cross-tenant access case
- applicable_scope:
  - auth/session refresh
- non_applicable_scope:
  - 纯前端 token 展示逻辑
- confidence:
  - low / medium / high
- action_hint:
  - proceed
  - proceed_with_caution
  - require_review
  - require_human_if_unverifiable
```

## 7.5 核心原则
- 知识命中只能降低不确定性，不能替代当前验证
- 知识只允许注入“最小必要内容”
- 若历史知识与当前上下文不匹配，应降权或忽略
- Knowledge Gate 的成功，不是命中越多越好，而是命中越准越好

---

# 8. Executor：执行器

## 8.1 职责
Executor 负责：

- 理解任务
- 参考 Knowledge Gate 摘要
- 修改代码 / 配置 / 流程
- 输出变更摘要
- 提交给 Base Validation

## 8.2 可用模型
当前现实约束下可用：
- Opus 4.6
- Codex

## 8.3 使用建议
- 需要深度分析、复杂依赖理解时，优先 Opus
- 需要快速实现、生成测试、补丁落地时，优先 Codex

## 8.4 输出结构建议
```text
SUMMARY:
- 做了什么
- 改了哪些文件
- 为什么这样改
- 参考了哪些知识条目

VALIDATION_PLAN:
- 将跑哪些基础验证

OPEN_RISKS:
- 目前仍不确定的点
```

---

# 9. Base Validation：基础验证

## 9.1 核心原则
基础验证不是“锦上添花”，而是整个系统里最接近客观裁判的部分。

## 9.2 输入来源
- git diff
- changed files
- 项目配置
- 已有测试入口
- 用户提供的复现步骤

## 9.3 验证优先级

### Python
- pytest
- ruff
- mypy
- pyproject scripts
- Makefile / justfile

### JS / TS
- npm/pnpm/yarn test
- eslint
- tsc --noEmit

### Shell
- shellcheck

### Docker / YAML / CI
- parse / lint / dry-run

### SQL / migration
- migration validate
- schema diff
- dry-run

### Docs-only
- 可选格式检查
- 不跑重测试

## 9.4 验证结果枚举
- `PASS`
- `FAIL_TEST`
- `FAIL_LINT`
- `FAIL_TYPECHECK`
- `FAIL_REPRO`
- `FAIL_VALIDATE`
- `NO_VALIDATOR_FOUND`

## 9.5 重要边界
- `NO_VALIDATOR_FOUND` 不等于通过
- 现有测试通过 ≠ reviewer 一定错
- 现有测试失败 ≠ executor 方案一定不可用
- 基础验证是证据之一，不是全部证据

---

# 10. Reviewer：第二模型复查器

## 10.1 重新定义 Reviewer
Reviewer 不是“再来一个模型随便提意见”，而是：

**把潜在问题转成可被裁决的主张。**

## 10.2 Reviewer 输入
- 用户原始需求
- 匿名 patch / diff
- Base Validation 输出
- Knowledge Gate 摘要
- 风险标签
- changeType

## 10.3 匿名化要求
不得暴露：
- 这是 Opus 写的
- 这是 Codex 审的
- 这是某某模型意见

允许使用：
- `Patch A`
- `Validation Output`
- `Knowledge Notes`
- `Review Context`

## 10.4 Reviewer 必须输出的字段
对每个 issue，至少输出：

- `location`
- `issue_type`
- `risk_statement`
- `why_it_matters`
- `verification_plan`
- `severity`

## 10.5 issue_type 枚举
- `runtime_bug`
- `logic_bug`
- `missing_test`
- `security_risk`
- `regression_risk`
- `requirement_conflict`
- `design_concern`

## 10.6 输出示例
```text
ISSUE:
- location: auth/session.py:84
- issue_type: security_risk
- severity: major
- risk_statement: 刷新 token 时未校验租户边界
- why_it_matters: 可能导致跨租户 session 污染
- verification_plan:
  - 生成 cross-tenant access case
  - 使用 tenant A token 访问 tenant B resource
  - 预期应返回 403
```

---

# 11. 核心改造：证据驱动裁决协议（Evidence-Driven Resolution Protocol）

这是本文档最关键的重构部分。

## 11.1 设计目标
在没有第三个独立仲裁模型的现实条件下，尽量减少“靠模型意见互相裁决”的不稳定性，把多数争议转成：

- 可执行验证
- 静态规则判断
- 历史知识裁决
- 最后才是人类拍板

## 11.2 基本思想
不要问：

> “第三个模型觉得谁更对？”

而要问：

> “这个 issue 能不能被证据确认、反证，或者证明当前无法裁决？”

## 11.3 裁决结果枚举

### `CONFIRMED`
reviewer 的 issue 被证据支持。

例：
- reviewer 指出缺租户边界校验
- 针对性测试失败
- 结论：必须修

### `REFUTED`
reviewer 的 issue 被**针对性反证**否定。

例：
- reviewer 说特定输入会崩
- 专门为该输入生成 targeted test 并稳定通过
- 结论：该 issue 驳回

### `UNVERIFIABLE`
当前无法通过测试、静态规则、历史知识确认或否定。

例：
- “这个设计未来可能难维护”
- 现阶段无法构造明确验证条件
- 结论：升级人工

### `REQUIREMENT_CONFLICT`
争议本质是需求或业务解释冲突，不是单纯技术问题。

例：
- executor 认为可以跨租户读取
- reviewer 认为必须 403
- 结论：直接升级给人

---

## 11.4 协议流程

### Phase 1：收集 issue
从 Reviewer 接收结构化 issues。

### Phase 2：尝试证据化
对每个 issue，优先将其转成以下一种或多种裁决方式：

1. **Targeted Test**
2. **Static Rule / Linter / Type Checker**
3. **Repro Step**
4. **Historical Decision Match（知识库裁决）**
5. **Risk Policy Match（内部规则命中）**

### Phase 3：执行裁决
若 issue 可转成证据，则执行证据计划并给出结果：
- `CONFIRMED`
- `REFUTED`

若不能转成足够证据，则给出：
- `UNVERIFIABLE`
- `REQUIREMENT_CONFLICT`

### Phase 4：驱动后续动作
- `CONFIRMED` → Executor 必修
- `REFUTED` → 记录并跳过
- `UNVERIFIABLE` → 升级人工
- `REQUIREMENT_CONFLICT` → 升级人工

---

## 11.5 重要边界

### 边界一：现有 pytest 全绿，不等于 reviewer 自动错
只有当 reviewer 的主张被**针对性反证**否定，才能 `REFUTED`。  
“现有测试都通过”只能说明当前覆盖到的路径没炸，不等于 reviewer 指出的路径不存在问题。

### 边界二：自动生成测试也不是绝对真理
自动生成的 targeted test 是“证据构造器”，不是“真理制造器”。  
测试写错、断言写弱、上下文理解偏差，都可能导致错误裁决。

### 边界三：知识库命中也不是自动裁决
历史知识只能作为“支持或警示证据”，不能替代当前任务的验证与上下文判断。

---

# 12. Human Escalation：人工升级兜底

## 12.1 什么时候升级给人
以下情况必须升级：

1. issue 被判定为 `UNVERIFIABLE`
2. issue 被判定为 `REQUIREMENT_CONFLICT`
3. 高风险域（auth / payment / migration / deploy）中存在重大未裁决问题
4. 证据之间互相冲突
5. targeted validation 本身不可靠
6. 多个 issue 累积后总体风险过高

## 12.2 人类应该看到什么
升级给人时，必须是高度结构化的上下文，而不是一大段原始对话：

- 原始需求
- 知识预检摘要
- patch 摘要
- Base Validation 结果
- Reviewer issues
- 每个 issue 的裁决状态
- 哪些是 `CONFIRMED`
- 哪些是 `REFUTED`
- 哪些是 `UNVERIFIABLE`
- 哪些是 `REQUIREMENT_CONFLICT`
- 推荐动作

## 12.3 人类的角色
人类不是来重新看完整个世界，而是来处理：

- 当前验证器无法覆盖的判断
- 当前知识库还不会的问题
- 当前需求本身有歧义的地方

---

# 13. Memory Writeback：第二大脑回写

## 13.1 为什么必须回写
如果每次人工兜底都不变成未来知识，系统永远不会真的“越用越省”。

## 13.2 默认回写时机
以下时机必须触发回写：

1. Tier 2 最终通过且形成了可复用经验
2. Tier 3 人工裁决完成
3. 高价值失败案例被确认
4. 某类 targeted validation 被证明有效
5. 某类 review 误报模式被识别

## 13.3 回写内容字段
每条知识至少包含：

- `decision_title`
- `task_summary`
- `applicable_scope`
- `non_applicable_scope`
- `final_decision`
- `why`
- `known_pitfalls`
- `validation_evidence`
- `issue_type`
- `review_or_human_required`
- `risk_tags`
- `changeType`
- `linked_issue`
- `linked_pr`
- `timestamp`
- `superseded_by`（可选）

## 13.4 去重与合并
回写前应先查重：

- 高相似则 merge/update
- 旧决策被推翻则标记 superseded
- 新坑点追加到原主题，而不是无穷增殖新条目

## 13.5 记忆质量要求
- 宁可少而准，不可多而乱
- 能明确说出“适用范围”和“不适用范围”
- 能明确指出“为什么会误导”
- 能支撑未来检索时的最小必要注入

---

# 14. GitHub Issue Trace：过程留痕

## 14.1 目标
- 让人工可以随时查看当前任务状态
- 让后续开发者能沿 issue 历史继续推进
- 让知识预检、证据裁决、人工拍板、知识回写都有可见记录

## 14.2 原则
- 沉淀关键决策，不沉淀全部原始对话
- 一个任务绑定一个主 issue
- 长任务可拆 sub-issues
- issue 中记录节点摘要
- 长日志放 artifact / markdown

## 14.3 推荐记录节点
- `INTAKE`
- `KNOWLEDGE_PRECHECK`
- `PLAN`
- `EXECUTOR_RESULT`
- `BASE_VALIDATION`
- `REVIEW_ISSUES`
- `EVIDENCE_RESOLUTION`
- `HUMAN_DECISION`
- `MEMORY_WRITEBACK`
- `FINAL_DELIVERY`

---

# 15. 预算机制

## 15.1 为什么保留预算
即使有第二大脑，Tier 2 / Tier 3 仍然有明显成本。  
预算不是财务系统，而是为了防止系统在早期阶段无节制升级。

## 15.2 V1 预算字段建议
```json
{
  "budget": {
    "maxTier2RunsPerDay": 20,
    "maxTier3RunsPerDay": 3,
    "maxHumanEscalationsPerDay": 5,
    "maxUnverifiableIssuesPerTask": 3,
    "warnOnTierOverflow": true
  }
}
```

## 15.3 默认策略
- 超出 Tier 2 / Tier 3 预算时，只允许显式升级
- 单任务 `UNVERIFIABLE` 超阈值时强制人工
- 超预算事件必须写入日志与 issue trace

---

# 16. 风险分类与 changeType

## 16.1 风险分类仍然保留
风险分类不是为了决定“谁更聪明”，而是为了决定：

- 是否需要 Knowledge Gate
- 是否需要 review
- 是否允许 skip review
- 是否需要人工兜底

## 16.2 高风险关键词 / 路径
- auth
- permission
- oauth
- token
- secret
- payment
- billing
- deploy
- migration
- schema
- prod
- acl

## 16.3 diff 内容模式分析
必须检查：
- token / session / jwt
- role / permission / tenant
- secret / credential / env
- migration / schema / index
- deploy / helm / docker / prod
- subprocess / remote call / shell exec

## 16.4 changeType 枚举
- `docs_only`
- `comment_only`
- `test_only`
- `logic_change`
- `config_change`
- `schema_change`
- `infra_change`
- `mixed_change`

## 16.5 低风险倾向
- docs_only
- comment_only
- test_only

## 16.6 不应轻易 skip review
- logic_change
- config_change
- schema_change
- infra_change
- mixed_change

---

# 17. Skip Review 的重新定义

V1 中，skip review 不再只是“改得少不值得审”。

真正允许 skip review 的条件必须同时满足：

1. Base Validation 全通过
2. changeType 为低风险倾向
3. 未命中高风险路径或 diff 模式
4. 修改规模小
5. 未新增依赖
6. 未涉及 auth / schema / deploy / migration
7. Knowledge Gate 命中高相似、已验证经验（可选）
8. 历史上同类问题返工率低
9. 当前任务没有开放性需求解释冲突

## 17.1 重要原则
- skip review 是“证据充分 + 风险低 + 历史稳定”的结果
- 不是“模型看起来很自信”的结果

---

# 18. 不再使用“第三模型仲裁”的说明

为了避免在 BashClaw / OpenClaw 文档里继续制造歧义，这里明确声明：

## 18.1 V1 不再采用以下设计
- 同一模型换 system prompt 假装第三仲裁者
- 通过角色扮演声称拥有第三独立视角
- 依赖模型主观口头判断做最终法官

## 18.2 取而代之
- 证据驱动裁决协议
- 人类兜底
- 知识回写
- 有限升级

## 18.3 保留 “critical / arbitration” 术语的方式
为了兼容原有文档和接口，仍可保留：
- `critical`
- `arbitration`

但在 V1 中它们的真实含义是：

> **高风险 / unresolved 问题的证据裁决与人工裁决流程**  
> 而不是“调用第三模型来拍板”。

---

# 19. 怎么证明这套系统真的有效

这是本文档的第二个核心主题。  
我们不接受“看起来挺聪明”这种模糊判断，而要求通过实验回答两个问题：

1. **闭环学习是否真的让系统越来越省 token？**
2. **复杂问题解决能力是否真的增强？**

---

# 20. 有效性证明：两个正式命题

## 20.1 命题 A：闭环学习效率命题
> 在时间顺序回放评测中，与“无第二大脑”的同配置系统相比，  
> token per resolved issue 显著下降，且 resolved rate 不下降。

这条用来证明：
- Knowledge Gate + Memory Writeback 真能减少高成本 review
- 第二大脑不是噪声仓库，而是有效记忆系统

## 20.2 命题 B：复杂问题能力提升命题
> 在单模型高失败率的 Hard Set 上，  
> 完整系统相对强单模型 baseline 的 solve rate 明显提升。

这条用来证明：
- 这套系统不仅更省，还更能解难题
- 提升来自“知识 + 证据裁决 + 有限升级”，而不是单纯多耗 token

---

# 21. 评测框架总览

评测必须分三层：

## 21.1 第一层：组件消融实验
回答：
- 到底是哪一层在起作用？

## 21.2 第二层：闭环学习实验
回答：
- 第二大脑是否真的让系统越用越省？

## 21.3 第三层：Hard Set 能力实验
回答：
- 复杂问题 solve rate 是否真的明显提高？

---

# 22. 组件消融实验设计

这是验证“哪些模块真的有价值”的基础。

## 22.1 最低实验矩阵
至少跑以下 6 组：

### A0：单模型 + Base Validation
- 只有 executor
- 无知识库
- 无 reviewer
- 无人工回写

### A1：单模型 + Base Validation + Knowledge Gate（只检索，不回写）
- 验证“知识预检本身”是否有帮助

### A2：单模型 + Base Validation + Knowledge Gate + Memory Writeback
- 验证“闭环学习”是否有增益

### B1：单模型 + Base Validation + Reviewer（无证据裁决）
- 验证传统 review 是否带来收益

### B2：单模型 + Base Validation + Reviewer + Evidence-Driven Resolution
- 验证“证据裁决协议”本身的价值

### C1：完整系统
- Knowledge Gate
- Executor
- Base Validation
- Reviewer
- Evidence-Driven Resolution
- Human Escalation
- Memory Writeback

## 22.2 可选扩展组
### C2：完整系统但关闭 Knowledge Gate
- 证明知识预检的价值

### C3：完整系统但关闭 Memory Writeback
- 证明闭环学习的价值

### C4：完整系统但关闭 Human Escalation
- 观察无人工兜底的极限表现

## 22.3 组件消融的目标
必须能回答：
- 提升来自知识库还是 review？
- 提升来自 reviewer 还是证据裁决？
- 没有人类兜底时系统会在哪些地方崩？
- 第二大脑到底是在帮忙，还是在加噪声？

---

# 23. 闭环学习实验设计（核心）

这是用来证明“越用越省 token”的最重要实验。

## 23.1 实验原则：必须按时间顺序回放
不能随机打散历史任务。  
必须模拟真实世界：

- 第一天只能看到第一天之前的知识
- 第二天可以使用第一天新增的知识
- 第三天可以使用前两天累计知识

否则你是在“偷看未来答案”，而不是验证闭环学习。

## 23.2 数据来源
建议优先使用你自己的真实任务历史：

- 真实 GitHub issues
- 真实 bugfix
- 真实 feature request
- 真实 refactor
- 真实 review 争议
- 真实高频回归问题

## 23.3 评测目标
观察随着 memory 累积，以下指标是否改善：

- resolved rate
- token per resolved issue
- review trigger rate
- human escalation rate
- knowledge hit precision
- harmful retrieval rate
- average time to resolution

## 23.4 闭环学习最关键的判断
如果系统有效，应该看到：

1. **resolved rate 不下降**
2. **token per resolved issue 下降**
3. **相似问题簇的 review 触发率下降**
4. **human escalation rate 在重复问题簇中下降**
5. **高价值 memory 的复用率上升**
6. **harmful retrieval rate 保持很低**

---

# 24. Hard Set 能力实验设计

这是用来证明“复杂问题解决能力增强”的核心实验。

## 24.1 为什么必须建 Hard Set
普通任务很容易被“都能做”掩盖差异。  
你真正关心的是：

> 原来强单模型也经常失败的问题，这套系统能不能明显更好？

## 24.2 Hard Set 定义建议
建立 `Hard-50` 或 `Hard-100`，筛选规则至少满足以下之一：

1. 你当前最强单模型 baseline 跑 3 次仍失败
2. Opus / Codex 都失败
3. 需要多文件修改
4. 需要 repo 级理解
5. 历史上人工也花较多时间
6. 涉及需求歧义或风险性架构判断

## 24.3 对比组
至少对比以下 4 组：

### H0：最强单模型 baseline
- 例如 Opus + Base Validation

### H1：单模型 + Reviewer
- 不带知识闭环

### H2：Knowledge Gate + 单模型 + Base Validation
- 看知识本身是否能拉升 Hard Set 表现

### H3：完整系统
- Knowledge Gate
- Reviewer
- Evidence-Driven Resolution
- Human Escalation
- Memory Writeback

## 24.4 Hard Set 的目标
不是证明“所有任务都提升 10 倍”，而是证明：

- 在 hard subset 上，系统相对 baseline 有显著提升
- 提升不是用失控成本换来的

---

# 25. 评测指标体系

下面是整个系统必须统一记录的指标。

---

## 25.1 结果类指标

### `Resolved Rate`
最终成功解决问题的比例。

### `Solve Rate on Hard Set`
Hard Set 上真正解决的比例。

### `Regression Rate`
交付后是否引入新问题。

### `Human Intervention Rate`
需要人工参与的比例。

---

## 25.2 成本类指标

### `Token per Resolved Issue`
每解决一个问题平均消耗多少 token。

### `Token per Hard Solved Task`
每解决一个 hard task 消耗多少 token。

### `Average Review Cost`
平均 review 成本。

### `Average Human Escalation Cost`
每次人工升级所带来的总代价。

---

## 25.3 流程类指标

### `Review Trigger Rate`
触发 Tier 2 的比例。

### `Critical / Human Escalation Rate`
触发 Tier 3 / 人工升级的比例。

### `Evidence Auto-Resolution Rate`
证据驱动裁决自动完成的 issue 比例。

公式：
```text
(CONFIRMED + REFUTED) / ALL_REVIEW_ISSUES
```

### `Unverifiable Issue Rate`
无法自动裁决的问题比例。

### `Requirement Conflict Rate`
需求冲突比例。

---

## 25.4 知识闭环类指标

### `Knowledge Hit Rate`
Knowledge Gate 有命中的比例。

### `Knowledge Hit Precision`
命中的知识中，真正对任务有帮助的比例。

### `Harmful Retrieval Rate`
命中的知识把任务带歪、误导决策的比例。

### `Memory Reuse Rate`
被后续任务再次复用的知识条目比例。

### `Review Reduction on Similar Clusters`
在高相似问题簇中，review 触发率是否随时间下降。

---

## 25.5 裁决质量类指标

### `Confirmed Issue Precision`
被 `CONFIRMED` 的 issue 中，事后证明确实应该修的比例。

### `Refuted Issue Precision`
被 `REFUTED` 的 issue 中，事后证明确实不需要修的比例。

### `Human Override Rate`
人类最终推翻自动裁决的比例。

### `Targeted Validation Usefulness`
targeted test / targeted check 真正帮助裁决的比例。

---

# 26. 实验日志字段要求

为了支持以上所有评测，系统必须在审计日志里记录这些字段。

```json
{
  "task_id": "20260324-abc123",
  "platform": "bashclaw | openclaw",
  "tier_requested": "reviewed",
  "tier_effective": "critical",
  "executor_model": "opus4.6",
  "reviewer_model": "codex",
  "changed_files": 4,
  "diff_lines": 126,
  "change_type": "logic_change",
  "risk_tags": ["auth", "token"],
  "knowledge_hits": ["KB-102", "KB-118"],
  "knowledge_confidence": "high",
  "knowledge_helpful": true,
  "base_validation": [
    {"name": "pytest", "status": "PASS"},
    {"name": "ruff", "status": "PASS"}
  ],
  "review_issue_count": 3,
  "confirmed_issue_count": 1,
  "refuted_issue_count": 1,
  "unverifiable_issue_count": 1,
  "requirement_conflict_count": 0,
  "targeted_validations": [
    {"issue_id": "I-1", "status": "FAILED", "result": "CONFIRMED"}
  ],
  "human_escalated": true,
  "human_final_decision": "must_check_tenant_boundary",
  "memory_writeback_status": "merged",
  "final_status": "DELIVERED",
  "resolved": true,
  "token_total": 18432
}
```

---

# 27. 验收标准（重点章节）

这是本文档最重要的部分。  
本系统的验收不能只写“能跑通”。必须分为：

1. **工程验收**
2. **流程验收**
3. **知识闭环验收**
4. **有效性验收**
5. **Hard Set 能力验收**
6. **上线门槛验收**

下面逐条给出可执行标准。

---

# 28. 工程验收标准

## 28.1 架构完整性验收
以下模块必须全部存在并可联通：

- Risk Classifier
- Knowledge Gate
- Executor
- Base Validation
- Reviewer
- Evidence-Driven Resolution
- Human Escalation
- Memory Writeback
- Issue Trace
- Audit Logging

### 通过标准
- 任一模块缺失则**不通过**
- 任一模块无法输出结构化结果则**不通过**
- 审计日志字段缺失关键项则**不通过**

---

## 28.2 平台适配验收
必须同时满足：

### BashClaw 侧
- 能在 repo 内运行完整流程
- 能触发 base validation
- 能输出结构化 issue resolution 结果

### OpenClaw 侧
- 能在任务链中调用 Knowledge Gate
- 能触发 review / critical 流程
- 能写入 issue trace 与 memory writeback

### 通过标准
- 只在单一平台跑通 = **不通过**
- 两平台共用逻辑但字段不一致 = **不通过**
- 两平台输出 schema 不统一 = **不通过**

---

# 29. 流程验收标准

## 29.1 Reviewer 质量验收
对抽样 review issue，必须满足：

- ≥ 95% 的 issue 带有 `location`
- ≥ 95% 的 issue 带有 `issue_type`
- ≥ 90% 的 issue 带有明确 `verification_plan`

### 不通过条件
- reviewer 仍大量输出“感觉有问题”“建议优化一下”这类空意见
- verification_plan 无法执行或无明确判定条件

---

## 29.2 证据裁决协议验收
在抽样任务中，Evidence-Driven Resolution 必须能稳定输出：

- `CONFIRMED`
- `REFUTED`
- `UNVERIFIABLE`
- `REQUIREMENT_CONFLICT`

### 通过标准
- ≥ 80% 的 review issues 能被正确归入四类之一
- 自动裁决链路可执行且结果可回放

### 不通过条件
- issue 大量停留在“没有结果”
- `REFUTED` 主要靠“已有测试全绿”而不是 targeted evidence
- `UNVERIFIABLE` 和 `REQUIREMENT_CONFLICT` 混用严重

---

## 29.3 Human Escalation 质量验收
人工升级包必须是结构化的，不允许要求人去读一坨原始对话。

### 通过标准
每个升级案例必须至少包含：
- 原始需求
- knowledge 摘要
- patch 摘要
- base validation 结果
- review issues
- 当前裁决状态
- 推荐动作

### 不通过条件
- 仍依赖人工自己翻全部日志
- 不知道为什么升级给人
- 不知道人要判断什么

---

# 30. 知识闭环验收标准

## 30.1 Knowledge Gate 命中质量验收
在抽样命中案例中：

### 通过标准
- `Knowledge Hit Precision ≥ 70%`
- `Harmful Retrieval Rate ≤ 5%`

### 不通过条件
- 命中很多，但大部分无关
- 命中内容经常误导执行或 review
- 第二大脑越大越乱

---

## 30.2 Memory Writeback 质量验收
回写条目必须具备：

- decision_title
- applicable_scope
- non_applicable_scope
- final_decision
- why
- known_pitfalls
- validation_evidence

### 通过标准
- 抽样回写条目字段完整率 ≥ 95%
- 重复条目 merge/update 正常率 ≥ 90%

### 不通过条件
- 大量知识条目没有适用边界
- 大量重复条目堆积
- 旧知识被推翻但没有 superseded 标记

---

## 30.3 闭环学习效果验收
这是第一核心验收标准之一。

### 通过标准（必须全部满足）
在时间顺序回放实验中，相对于“无第二大脑”的同配置系统：

1. `Resolved Rate` 不下降超过 2 个百分点
2. `Token per Resolved Issue` 下降 **至少 30%**
3. 高频相似问题簇中的 `Review Trigger Rate` 下降 **至少 20%**
4. 高频相似问题簇中的 `Human Escalation Rate` 下降 **至少 20%**
5. `Harmful Retrieval Rate ≤ 5%`

### 强通过标准（优秀）
1. `Token per Resolved Issue` 下降 **至少 40%**
2. 相似问题簇中的 `Review Trigger Rate` 下降 **至少 30%**
3. 相似问题簇中的 `Human Escalation Rate` 下降 **至少 30%**

### 不通过条件
- token 成本没有下降
- review / human escalation 不降反升
- resolve 率明显下降
- 知识命中经常带歪任务

---

# 31. 复杂问题能力验收标准

这是第二核心验收标准。

## 31.1 Hard Set 定义验收
Hard Set 必须满足：

- 至少 50 个任务（建议 50 或 100）
- 至少 70% 为真实仓库问题
- 至少 50% 为多文件问题
- 至少 30% 涉及 repo 级理解
- 至少 20% 涉及高风险域或需求歧义

### 不通过条件
- Hard Set 太简单
- Hard Set 主要是文档题 / 低风险题
- Hard Set 无法代表真实难题

---

## 31.2 Hard Set 提升验收
相对于最强单模型 baseline：

### 通过标准
- `Solve Rate on Hard Set` 提升 **至少 2x**
- `Human Intervention Rate` 不得无限飙升
- `Token per Hard Solved Task` 不得失控到 baseline 的 5x 以上

### 强通过标准
- `Solve Rate on Hard Set` 提升 **至少 3x**
- `Token per Hard Solved Task` 控制在 baseline 的 **3x 以内**
- `Regression Rate` 不高于 baseline

### 仅限窄口径宣传标准
若要使用“10x 提升”表述，必须同时满足：
1. 仅限 Hard Subset，不得作为全局 claim
2. baseline solve rate ≤ 5%
3. system solve rate ≥ baseline 的 10 倍
4. 成本增长可解释且未失控
5. 必须在文档中明确写出这是 hard subset claim

### 不通过条件
- solve rate 提升不明显
- 虽然 solve rate 上去了，但成本完全失控
- 只是在简单题上看起来变好
- 提升来自偷看未来知识或数据泄露

---

# 32. 组件消融验收标准

## 32.1 为什么必须做
如果不做消融，你永远无法证明真正有用的是：
- 第二大脑
- reviewer
- 证据裁决
- 还是人工兜底

## 32.2 通过标准
消融结果必须能清楚回答：

1. Knowledge Gate 是否独立带来收益
2. Memory Writeback 是否独立带来收益
3. Reviewer 不加证据裁决时，是否存在明显噪声
4. Evidence-Driven Resolution 是否能显著降低 unverifiable 比例
5. Human Escalation 去掉后，哪些类问题最先失效

### 不通过条件
- 消融矩阵不完整
- 结果无法解释
- 最终只能说“整体看起来还行”

---

# 33. 上线门槛验收标准（最终门槛）

只有同时满足下面所有条件，系统才可被视为 V1 达标：

## 33.1 工程门槛
- 两平台（BashClaw / OpenClaw）均可跑通完整核心链路
- 审计日志完整
- issue trace 完整
- memory writeback 可用

## 33.2 闭环学习门槛
- token per resolved issue 相对基线下降 **至少 30%**
- review trigger rate 在相似问题簇中下降 **至少 20%**
- harmful retrieval rate ≤ **5%**

## 33.3 复杂能力门槛
- Hard Set solve rate 相对最强单模型 baseline 提升 **至少 2x**
- regression rate 不高于 baseline
- human intervention rate 在可接受范围内（需结合团队容量定义）

## 33.4 裁决质量门槛
- ≥ 80% 的 review issues 可被归类为 `CONFIRMED / REFUTED / UNVERIFIABLE / REQUIREMENT_CONFLICT`
- `REFUTED` 不得主要依赖“已有测试全绿”的偷懒判断
- Human Override Rate 应低于 **20%**
  - 若高于 20%，说明自动裁决不可信

## 33.5 知识质量门槛
- Knowledge Hit Precision ≥ **70%**
- Memory Reuse Rate 有持续上升趋势
- 无明显知识污染和记忆爆炸问题

### 任一项不满足 → V1 不算通过

---

# 34. 推荐实施顺序

## Phase 1：工程底座
- Risk Classifier
- Knowledge Gate
- Executor
- Base Validation
- 审计日志

## Phase 2：Reviewer 结构化
- reviewer 改成输出 issue_type + verification_plan
- 实现匿名 review 输入

## Phase 3：证据驱动裁决协议
- 实现 `CONFIRMED / REFUTED / UNVERIFIABLE / REQUIREMENT_CONFLICT`
- 接入 targeted validation

## Phase 4：Human Escalation + Memory Writeback
- 结构化人工升级包
- 人工决策回写知识库

## Phase 5：Issue Trace
- GitHub issue milestones
- ledger comment

## Phase 6：评测体系
- 组件消融
- 时间顺序回放
- Hard Set

---

# 35. 非目标

V1 不追求：

- 不追求“所有任务都多模型协商”
- 不追求“第三模型假仲裁”
- 不追求“知识库越大越好”
- 不追求“上下文越长越聪明”
- 不追求“靠 prompt 表演出来的第三视角”
- 不追求“没有人工也能覆盖所有高风险问题”
- 不追求“先讲商业化、后验证价值”

---

# 36. 最终结论

这套系统的价值，不在于“又做了一个多 agent 讨论框架”，而在于：

1. **先查历史知识，再决定要不要花 review 成本**
2. **把 review 变成可验证主张，而不是口水战**
3. **把大部分争议交给证据裁决，而不是模型互判**
4. **把真正无法裁决的问题交给人**
5. **把人的判断沉淀回第二大脑**
6. **通过时间顺序回放和 Hard Set 评测，证明系统既更省，又更强**

如果这套文档定义的验收标准能被满足，那么你就不是“感觉做了一套聪明系统”，而是**真正证明了一套闭环学习型开发决策系统是有效的**。
