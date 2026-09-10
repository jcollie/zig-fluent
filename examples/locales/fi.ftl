### SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
### SPDX-License-Identifier: MIT

-app-name = Kuvakirjasto

# Finnish inflects the name rather than putting a preposition in front of it,
# and the illative ending is written after the placeable: "Tervetuloa
# Kuvakirjastoon!". That is what a term is for -- the translator reaches the
# product name and declines it, without the calling code knowing there is a
# case system to worry about.
welcome = Tervetuloa { -app-name }on!

# Two plural categories, as in English -- but a noun counted by a numeral goes
# into the partitive, so the difference between one photo and several is not
# only the numeral in front of it: "1 uusi kuva", "2 uutta kuvaa".
new-photos =
    { $count ->
        [0] Ei uusia kuvia
        [one] { $count } uusi kuva
       *[other] { $count } uutta kuvaa
    }

# Finnish has no grammatical gender at all, and its third-person pronoun is
# the same word for anyone, so `$gender` is passed to this message and simply
# never read. That is the other half of what Fluent is for and the half that
# is easier to forget: a translation may ignore an argument the calling code
# believed was essential, and nothing needs to be changed for it to.
shared-with-you =
    { $user } jakoi kanssasi { $count ->
        [one] kuvan
       *[other] { $count } kuvaa
    } { DATETIME($when, dateStyle: "long") }.

storage =
    Käytössä { NUMBER($used, maximumFractionDigits: 1) } Gt / { $total } Gt
