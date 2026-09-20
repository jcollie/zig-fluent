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

## The window itself.
##
## A GUI is translated the same way its sentences are: the menu labels, the
## button and its tooltip are messages like any other. `.tooltip` is an
## attribute -- one message carrying several strings that belong together,
## which is what keeps a control's label and its explanation from drifting
## apart in a translation.

# The language menu shows every entry under its own name, read from this
# message inside each translation, so nobody has to recognize their language
# written in one they cannot read yet.
language-name = English

window-title = { -app-name }

language-label = Language
count-label = New photos

use-system-language = Use system language
    .tooltip = Ask this computer which language you prefer
