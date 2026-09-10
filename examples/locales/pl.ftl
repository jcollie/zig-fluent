### SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
### SPDX-License-Identifier: MIT

# Polish declines the product name, and the stem changes rather than only the
# ending -- "Skarbiec" becomes "Skarbcu" -- so writing a suffix after the
# placeable, the way Finnish can, would not do here. A term called with an
# argument is Fluent's answer: the translator lists the forms and each sentence
# asks for the one it needs, while the calling code goes on passing nothing.
-app-name =
    { $case ->
        [locative] Skarbcu Zdjęć
       *[nominative] Skarbiec Zdjęć
    }

welcome = Witamy w { -app-name(case: "locative") }!

# All four of Polish's categories, written out. `few` is the interesting one:
# 2 to 4 take it, but 12 to 14 do not -- so 22 counts like 2 and 12 counts like
# 5. The noun changes case with the category, not just the adjective.
#
# `other` is not a fifth quantity but the fractional one, and Polish puts a
# fraction in the genitive *singular*: "1,5 nowego zdjęcia", not the genitive
# plural that whole numbers from five up take. Leaving it to default into
# `many` would have been wrong and would have looked right.
new-photos =
    { $count ->
        [0] Brak nowych zdjęć
        [one] { $count } nowe zdjęcie
        [few] { $count } nowe zdjęcia
        [many] { $count } nowych zdjęć
       *[other] { $count } nowego zdjęcia
    }

# The past tense agrees with the sharer's gender: "udostępniła" for Ada,
# "udostępnił" for Adam. The program knows only that it has a gender to hand
# over, and this is where knowing what to do with it lives.
shared-with-you =
    { $user } udostępni{ $gender ->
        [female] ła
       *[other] ł
    } ci { $count ->
        [one] zdjęcie
        [few] { $count } zdjęcia
       *[many] { $count } zdjęć
    } { DATETIME($when, dateStyle: "long") }.

storage =
    Wykorzystano { NUMBER($used, maximumFractionDigits: 1) } GB z { $total } GB
