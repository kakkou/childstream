# ChildStream

ChildStreamは、WindowsのChild SessionでゲームとSunshineを動かし、物理コンソールを使い続けながらMoonlightクライアントへ配信する実験的なランチャーです。

WindowsのChild Sessions API（`WTSEnableChildSessions`、`WTSGetChildSessionId`）とRDP ActiveXの`ConnectToChildSession`を使用します。通常のRDPセッションや物理コンソールをChild Sessionとして推測する処理は行いません。

## 必要環境

- Windows 10／11 Pro（Windows 11 Pro 25H2で開発）
- NVENC／AMF／QSVなどのハードウェアエンコーダーを備えたGPU
- .NET Framework 4.x
- パスワードでサインインできるWindowsアカウント
- セットアップ時の管理者権限

Windows Helloだけを使用しているMicrosoftアカウントでは、Child Sessionへのログオン用にパスワードサインインを許可してください。

## Setup

管理者として開いたWindows PowerShell 5.1で、リポジトリのルートから実行します。

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\scripts\setup.ps1
```

既定の`HighestTask`モードは、現在のユーザーに対する対話型ログオントリガーと「最上位の特権」でタスクを登録します。Child Session内で正しくタスクが起動する環境では、ログオンごとのUAC操作を避けられます。

```powershell
.\scripts\setup.ps1 -AutostartMode HighestTask
```

最高権限タスクがChild Session内に配置されない環境では、いったん`uninstall.ps1`で変更前状態へ復元してから、UACを許容する`PromptedStartup`でセットアップし直します。保存済みの変更前状態を上書きしないため、既存インストールへの上書きセットアップは拒否されます。

```powershell
.\scripts\uninstall.ps1 -WhatIf
.\scripts\uninstall.ps1
.\scripts\setup.ps1 -AutostartMode PromptedStartup
```

既存のSunshineディレクトリが固定配布物と一致しない場合、セットアップは上書きせず停止します。内容を確認したうえで置換する場合だけ、次を明示してください。既存配置は`%ProgramData%\ChildStream\Backups`以下へ退避してから置換されます。

```powershell
.\scripts\setup.ps1 -ReplaceExistingSunshine
```

セットアップは次の処理を行います。

1. `src`のC#ソースから`ChildStream.exe`をコンパイルする
2. Child Sessions、RDP、DWM設定などの変更前状態を記録する
3. Sunshineの固定配布物をダウンロードし、展開前にSHA-256を検証する
4. Child SessionだけでSunshineを起動する自動起動設定を登録する
5. Private／LocalSubnet限定のFirewall受信規則を登録する
6. デスクトップショートカットを作成する

Sunshineは次の配布物に固定されています。

- バージョン: `v2026.914.233613`
- ファイル: `Sunshine-Windows-AMD64-lite.zip`
- SHA-256: `233008e46f4c0e501a586cbfd6c4fd4a4c0d414a0b5fc7f13c070eb92ec3824b`

ハッシュが一致しない場合は展開もシステム変更も行いません。

セットアップ後、SunshineのWeb UI資格情報を設定し、Moonlight／ArtemisをChildStream用ポートへペアリングしてください。

```powershell
.\Sunshine\Sunshine\sunshine.exe --creds <ユーザー名> <パスワード>
```

## display.cfg

リポジトリのルートに`display.cfg`を置くと、Child Sessionの解像度とスケールを指定できます。

```text
WIDTHxHEIGHT
WIDTHxHEIGHTxSCALE
```

例:

```text
2800x1272x225
```

区切り文字は`x`または`X`です。許容範囲は次のとおりです。

- 幅: 640～8192
- 高さ: 480～8192
- スケール: 指定する場合は100～500

ファイルがない場合は1920×1080、スケール指定なしを使用します。余分な項目、符号、小数、範囲外、整数オーバーフローなどの不正な値がある場合は、パスワード入力やRDP接続を開始せず安全に停止します。

## Security

- Child Session IDは`WTSGetChildSessionId`で取得し、通常のRDPやユーザー名検索から推測しません。
- 「End session」は、操作直前に取得したChild Session IDだけを`WTSLogoffSession`へ渡します。取得に失敗した場合、別セッションを列挙してログオフするフォールバックはありません。
- コンソール側は短時間だけ有効な起動許可を`%LOCALAPPDATA%\ChildStream\active-child-session.json`へ発行します。パスワードやDPAPIデータは保存しません。
- Child Session側はSession ID、有効期限、ランチャーのプロセスIDと起動時刻を再検証し、不一致ならSunshineを起動しません。
- 同一Session内のSunshineは実行ファイルの完全パスでも識別します。通常利用の別インストール版はChildStream同梱版とみなさず、パスを確認できない場合は安全側で起動を拒否します。
- Firewall規則は受信方向、Privateプロファイル、`RemoteAddress=LocalSubnet`に限定されます。Publicネットワークやインターネット全体には公開しません。
- 初回セットアップ前の状態は`%ProgramData%\ChildStream\install-state.json`へ保存し、変更の進行状況は同じディレクトリの`install-journal.json`へ記録します。最初の正常なスナップショットは再セットアップで上書きしません。

## 使用上の注意

- 配信中はChildStreamを終了せず、最小化してトレイへ格納してください。
- ビューアーを切断してもChild Session自体は維持されますが、表示が接続されていない間はキャプチャできません。
- Child Sessionを終了する場合は、トレイメニューの「End session」またはChild Session内のサインアウトを使用します。
- 対応するChild Sessionは1つです。
- RDPコンポジターによるリフレッシュレート上限があり、セッション単位のHDRには対応していません。

## Uninstall／rollback

手動でレジストリ、Firewall、タスク、Startupファイルを削除しないでください。管理者として開いたWindows PowerShell 5.1から、最初に`-WhatIf`で復元内容を確認します。

```powershell
.\scripts\uninstall.ps1 -WhatIf
.\scripts\uninstall.ps1
```

`uninstall.ps1`は`install-state.json`と`install-journal.json`を検証し、記録された変更だけを逆順に復元します。状態ファイルがない、壊れている、または不整合な場合は、推測による変更を行わず停止します。

復元時に現行のSunshineや状態ファイルを取り除く必要がある場合も削除せず、`%ProgramData%\ChildStream\Backups\<日時>`へ移動します。アンインストール後に問題がある場合は、画面に表示されたバックアップ先を確認し、必要なファイルを元の場所へ戻してください。既存Sunshineを置換した場合は、同じバックアップ領域に置換前のディレクトリが保存されます。

セットアップ途中でエラーになった場合も、永続ジャーナルに基づいて今回適用した変更だけをロールバックします。

## Manual verification

コード実装はWindows CIの構文検査、C#ビルド・単体テスト、PowerShell単体テストに合格しています。ただし、Windows実機での動作確認は未完了です。導入前の証跡採取、停止条件、各コマンド、期待結果、uninstall後の比較方法は[Windows実機確認フロー](docs/windows-real-device-verification.md)を参照してください。

概要として、導入先の実機で次を確認してください。

1. 物理コンソールへログオンしても、ChildStream用Sunshineが自動起動しない。
2. mstscなどによる通常のRDPログオンでも、ChildStream用Sunshineが自動起動しない。
3. ChildStreamからChild Sessionを作成した場合だけ、Sunshineが同じSession IDで起動する。
4. 「End session」で対象のChild Sessionだけがログオフされ、コンソールと通常RDPが維持される。
5. `Get-NetFirewallRule`と`Get-NetFirewallAddressFilter`で、ChildStream規則がPrivate／LocalSubnet限定である。
6. 不正な`display.cfg`でメッセージが表示され、パスワード入力やRDP接続が行われない。
7. `HighestTask`でログオン時のUACなしにSunshineがChild Session内へ配置される。
8. WGCキャプチャ、NVENC／AMF／QSV、Moonlightペアリング、昇格アプリへの入力が実機で機能する。
9. `uninstall.ps1 -WhatIf`の内容を確認後にアンインストールし、変更前の設定へ戻る。

項目7を満たさない場合は、`PromptedStartup`モードへ切り替えてください。この場合はChild Sessionログオン時に1回のUAC操作が必要ですが、起動許可の検証は維持されます。

## Credits

- [DuoStream/Duo](https://github.com/DuoStream/Duo) — Child Sessionによる配信方式の先行実装
- [LizardByte/Sunshine](https://github.com/LizardByte/Sunshine) — 配信ホスト
- [Artemis / moonlight-android](https://github.com/ClassicOldSong/moonlight-android) — クライアント
- [Microsoft Child Sessions API](https://learn.microsoft.com/windows/win32/termserv/child-sessions)

## Disclaimer

本ソフトウェアは実験的なProof of Conceptです。保証はありません。変更前状態の記録と`-WhatIf`を確認し、復元可能なバックアップを用意したうえで使用してください。
