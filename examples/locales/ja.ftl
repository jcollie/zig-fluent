### SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
### SPDX-License-Identifier: MIT

-app-name = フォトボールト

welcome = { -app-name }へようこそ！

# Japanese has one plural category and uses it for every count.
new-photos =
    { $count ->
        [0] 新しい写真はありません
       *[other] 新しい写真が{ $count }枚あります
    }

shared-with-you =
    { DATETIME($when, dateStyle: "long") }に{ $user }さんが写真{ $count }枚を共有しました。

storage =
    { $total } GB 中 { NUMBER($used, maximumFractionDigits: 1) } GB 使用中
