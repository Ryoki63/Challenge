# Challenge — Claude 自律ループ実行システム

Addy Osmani の [Loop Engineering](https://addyosmani.com/blog/loop-engineering/)（Ralph パターン）に基づく、
Claude Code がこのフォルダ上で**自律的にタスクをぐるぐる処理する**仕組みです。

> Loop engineering is replacing yourself as the person who prompts the agent.
> You design the system that does it instead.

## 何を作っているか

月3万円の継続収益を目指す個人開発プロジェクト。
現在のプロダクトは **ふたり習慣（仮称）** — 2人で約束を1つだけして、ふたりで続ける習慣アプリ。
企画の決定事項・海外事例エビデンス・MVPスコープは [docs/CONCEPT.md](docs/CONCEPT.md) 参照。

## 仕組み

```
ralph.ps1 (外側のループ)
   └─> claude -p "LOOP.mdに従え" を繰り返し起動
         └─> 1回の起動 = BACKLOG の先頭タスクを1件だけ処理
               1. tasks/BACKLOG.md から先頭タスクを取る
               2. 実行する
               3. 検証する（サブエージェントによる独立チェック）
               4. DONE.md へ移動・JOURNAL.md に記録・git commit
               5. 終了シグナルを出す
                  <LOOP_CONTINUE> → 次のイテレーションへ
                  <LOOP_COMPLETE> → BACKLOG が空。ループ正常終了
                  <LOOP_BLOCKED>  → 人間の判断待ち。ループ停止
```

エージェントは毎回まっさらな状態で起動しますが、**状態はファイルと git 履歴が覚えています**
（The agent forgets, the repo doesn't）。

## 使い方

### 1. タスクを積む

`tasks/BACKLOG.md` に1行1タスクで追加します。

```markdown
- [ ] ToDoアプリの雛形を Next.js で web/ に作る。完了条件: npm run build が通ること。
```

### 2. ループを回す

**方法A: ターミナルから（ヘッドレス・推奨）**

```powershell
cd $HOME\Desktop\挑戦
.\ralph.ps1 -MaxIterations 10
```

BACKLOG が空になるか、ブロックが発生するか、上限回数に達するまで回り続けます。

**方法B: VS Code のチャットセッション内から**

```
/loop LOOP.md の指示に従ってタスクを処理して
```

組み込みの `/loop` スキルがセッション内で自己ペース実行します。

### 3. 結果を確認する

- `progress/JOURNAL.md` — 各イテレーションの実行記録（監査ログ）
- `tasks/DONE.md` — 完了タスク一覧
- `git log --oneline` — 1タスク = 1コミットの履歴

## 安全装置（ガードレール）

| 装置 | 内容 |
|------|------|
| 1実行1タスク | スコープの暴走を防ぐ。粒度はコミット単位 |
| MaxIterations | ralph.ps1 の上限回数。無限ループを物理的に防止 |
| BLOCKED 停止 | 曖昧・失敗時は推測で進まず停止して人間に質問を残す |
| push 禁止 | タスクに明記しない限りローカル commit まで |
| 追記専用ログ | JOURNAL/DONE は改変禁止。監査可能性を確保 |

## 注意（記事の警告より）

- **検証責任は人間に残る** — 放置ループは放置ミスを生む。JOURNAL と diff は必ず読むこと
- **理解の劣化に注意** — 生成が速いほど、中身を読まないと自分のコードベースが分からなくなる
- ループを作っても「エンジニアであり続ける」こと。Press Go だけの人にならない
