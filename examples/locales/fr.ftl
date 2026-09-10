### SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
### SPDX-License-Identifier: MIT

-app-name = Coffre à photos

welcome = Bienvenue dans { -app-name } !

new-photos =
    { $count ->
        [0] Aucune nouvelle photo
        [one] Une nouvelle photo
       *[other] { $count } nouvelles photos
    }

shared-with-you =
    { $user } a partagé { $count ->
        [one] une photo
       *[other] { $count } photos
    } avec vous le { DATETIME($when, dateStyle: "long") }.

storage =
    { NUMBER($used, maximumFractionDigits: 1) } Go sur { $total } Go utilisés
