### SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
### SPDX-License-Identifier: MIT

# The name of the product, factored out so that a translator can inflect it
# and so that changing it is one edit rather than forty.
-app-name = Photo Vault

welcome = Welcome to { -app-name }!

new-photos =
    { $count ->
        [0] No new photos
        [one] One new photo
       *[other] { $count } new photos
    }

shared-with-you =
    { $user } shared { $count ->
        [one] a photo
       *[other] { $count } photos
    } with you on { DATETIME($when, dateStyle: "long") }.

storage =
    { NUMBER($used, maximumFractionDigits: 1) } GB of { $total } GB used
