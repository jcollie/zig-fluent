### SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
### SPDX-License-Identifier: MIT

-app-name = Фотохранилище

welcome = Добро пожаловать в { -app-name }!

# Russian needs four forms where English needs two, and 11 is not 1.
new-photos =
    { $count ->
        [0] Нет новых фотографий
        [one] { $count } новая фотография
        [few] { $count } новые фотографии
       *[many] { $count } новых фотографий
    }

shared-with-you =
    { $user } поделил{ $gender ->
        [female] ась
       *[other] ся
    } с вами { $count ->
        [one] { $count } фотографией
        [few] { $count } фотографиями
       *[many] { $count } фотографиями
    } { DATETIME($when, dateStyle: "long") }

storage =
    Занято { NUMBER($used, maximumFractionDigits: 1) } ГБ из { $total } ГБ
