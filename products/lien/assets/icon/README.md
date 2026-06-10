# アプリアイコン(T26 / issue #26)

| ファイル | 内容 |
|---|---|
| `icon_1024.png` | 本命(1024×1024・RGB透過なし・角丸なし=Apple が適用)。App Store Connect / AppIcon.appiconset にそのまま使う |
| `icon_drafts/draft_a_bloom_1024.png` | A案: 開花クローズアップ(小サイズで最も大胆) |
| `icon_drafts/draft_b_buddy_1024.png` | B案: 鉢の相棒+双葉+ハート(**本命**。アプリ内マスコットと同一トーン) |
| `icon_drafts/draft_c_heart_1024.png` | C案: 双葉ハート(最も概念的・「絆」シンボル) |
| `icon_drafts/contact_sheet.png` | G4 レビュー用の3案比較シート |
| `tools/gen_icon.py` | ジェネレータ(純Python・決定論的。Pillow不要) |

## 設計判断

- 16×16 ピクセル格子 × 64倍整数拡大 = 1024(ネオドット絵の整数スケール、REQUIREMENTS §0)
- パレット・背景色は `assets/plant/tools/gen_sprites.py` と同一(アプリ内植物とトーン一致)
- B案を本命にした理由: アプリ内マスコット(顔つきの鉢)そのもの+双葉=「ふたり」+ハート=「絆」。
  鉢の顔が「罰のないやさしさ」を最小面積で伝える

## 差し替え方法(G4 で別案採用になったら)

`tools/gen_icon.py` の `CHOSEN` を `draft_a_bloom` / `draft_c_heart` に変えて再実行:

```
python3 tools/gen_icon.py
```
