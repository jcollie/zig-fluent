### SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
### SPDX-License-Identifier: MIT

-app-name = Fototresor

welcome = Willkommen bei { -app-name }!

new-photos =
    { $count ->
        [0] Keine neuen Fotos
        [one] Ein neues Foto
       *[other] { $count } neue Fotos
    }

shared-with-you =
    { $user } hat am { DATETIME($when, dateStyle: "long") } { $count ->
        [one] ein Foto
       *[other] { $count } Fotos
    } mit dir geteilt.

storage =
    { NUMBER($used, maximumFractionDigits: 1) } GB von { $total } GB belegt
