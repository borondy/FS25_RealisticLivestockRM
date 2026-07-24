# Saved Filters

Saved filters are named, reusable searches that narrow a long animal list down to just the animals you care about. Build a filter once - "old cows that aren't pregnant", "top-genetics breeding bulls" - and reuse it on the Buy, Sell, Move, and Manage screens. Filters are also how the [Herdsman](guide-herdsman.md) decides which animals to act on, so they are worth learning early.

> **Note:** This documentation was generated with AI assistance and may contain inaccuracies. If you spot an error, please [open an issue](https://github.com/rittermod/FS25_RealisticLivestockRM/issues).

---

## What a filter does

A filter is a set of **conditions** - small tests like "age is 30 months or more" or "is not pregnant". An animal is shown only if it matches. Conditions combine one of two ways:

- **Match all (AND)** - the animal must satisfy *every* condition.
- **Match any (OR)** - the animal must satisfy *at least one* condition.

You pick which mode a filter uses when you create it.

---

## Where to find them

Open the **RL Menu** (default **Right Shift + O**, or press **R** at one of your pens), go to the **Settings** tab, and switch to the **Filters** sub-tab.

- The **left** side lists your saved filters.
- The **right** side is the editor for the selected filter.

---

## Creating a filter

1. Press **New filter**.
2. Give it a **name** - this is what you'll see on the filter chip when cycling filters in-game.
3. Set the **animal type** - scope the filter to one species (Cows, Sheep, Pigs, ...) or leave it as **Any** to use it everywhere.
4. Set **Show on** - where the filter should appear:
   - **All screens**
   - **Owned-herd screens** (Sell, Move, Manage)
   - **Dealer screens** (Buy)

   This keeps a "cull my herd" filter off the dealer's Buy screen, and a "good bulls to buy" filter off your own-herd screens.
5. Choose **Match all** or **Match any** for how the conditions combine.

---

## Create one from a Quick filter

Every animal screen also has a **Quick filter** - a throwaway, one-off narrowing you open with the on-screen **Filter** button. It is not saved and resets when you leave the screen. If you build a Quick filter you would rather keep, you don't have to rebuild it here by hand:

1. On the **Buy**, **Sell**, **Move**, or **Manage** tab, press **Filter** to open the Quick filter.
2. Set it up the way you want.
3. Press **Save filter**.

The mod turns it into a saved filter and drops you straight into the editor with the new filter selected - so you can rename it, set its **animal type** and **Show on** scope, and fine-tune the conditions.

A few notes:

- **Save filter** needs the **trade animals** permission (the same one that gates **New filter**) and a farm.
- It appears on the RL Menu's own tabs. If you open a livestock **dealer** directly - a walk-up dealer, or the shop's *Buy Animals* button - there is no Settings tab to tune the filter in, so the button is hidden; open the RL Menu from one of your pens instead.
- The Quick filter's **Value** (price) slider has no saved-filter equivalent yet, so if you narrowed it, that one condition is left behind (the mod warns you). Everything else carries over.

---

## Adding conditions

With a filter selected, press **Add condition**. A small dialog asks for three things:

- **Field** - what to test (Age, Gender, a genetics trait, Breed, and so on).
- **Compare** - *how* to test it, shown as a short comparison symbol (`>=`, `==`, `contains`, ...). The symbols are explained just below.
- **Value** - what to match against.

For example, Field **Age**, Compare **`>=`**, Value **30** becomes the row `Age >= 30` - "age is 30 months or more". Each condition becomes a row; select a row to **Edit** or **Delete** it.

### Reading the comparison symbols

The **Compare** picker uses the same short symbols you see in each saved condition row. They come from maths and programming, so they can look cryptic at first - here is what each one means in plain English, with a livestock example:

| Symbol | Say it as | Example row | Matches |
|--------|-----------|-------------|---------|
| `>=` | is **at least** (this or higher) | `Age >= 30` | animals 30 months and older |
| `>` | is **more than** (over) | `Weight > 500` | animals over 500 |
| `<=` | is **at most** (this or lower) | `Age <= 12` | animals 12 months and younger |
| `<` | is **less than** (under) | `Genetics: overall < 50` | animals under 50 overall genetics |
| `==` | **is** | `Pregnant == No` | animals that are not pregnant |
| `!=` | **is not** | `Gender != Male` | every animal except males (so, females) |
| `in` | is **one of** | `Breed in [Holstein, Jersey]` | Holstein or Jersey animals |
| `notin` | is **none of** | `Breed notin [Holstein, Jersey]` | every breed except those two |
| `contains` | name **includes** | `Name contains betty` | Betty, Bettyboop, ... (any name with "betty") |
| `notcontains` | name **excludes** | `Name notcontains keep` | any name without "keep" in it |

Reading them aloud helps:

- `==` is a **double** equals sign - just read it as "**is**". `Castrated == Yes` means "castrated: yes".
- The `!` in `!=` means "**not**", so `!=` reads as "**is not**".
- The line under `>=` and `<=` adds "**or equal to**", so `Age >= 30` *includes* an animal that is exactly 30.
- The open mouth of `<` and `>` always faces the **bigger** amount: `Weight > 500` is "weight is bigger than 500".

Which symbols you can pick depends on the field:

- **Number** fields (Age, Weight, Health, Genetics) offer all six of `<` `<=` `==` `!=` `>=` `>`, plus `in` / `notin` to match a list of exact values.
- **Yes/no** fields (Pregnant, Castrated, Has a name, ...) only use `==`, matched against **Yes** or **No**.
- **Gender** and **Breed** use `==` / `!=` for a single value, or `in` / `notin` for a list.
- **Name** uses `contains` / `notcontains` only.

A couple more things worth knowing:

- **Genetics are shown on a 0-99 scale** - the same number you see on the animal's info card. `Genetics: overall >= 75` does what you'd expect.
- **Text matching is not case-sensitive** - `Name contains betty` also matches "Betty" and "BETTY".

---

## What you can filter on

The most useful fields:

- **Age** (in months)
- **Gender**, **Breed** (the specific subtype)
- **Genetics** - health, fertility, productivity, quality, metabolism, and overall (0-99)
- **Pregnant**, **Lactating** (cows), **Castrated**
- **Name** / **Has a name**
- **Has a disease**, **Has a mark**
- **Weight** and **Health** - but only for animals with an **active monitor**; without one, these tests never match, so pair them with another condition.

For the complete field-and-comparator reference - and for power users who want to hand-write filters in the save file - see [Hand-Crafting Saveable Filters](filter-preview.md).

---

## Using a filter in-game

On the **Buy**, **Sell**, **Move**, and **Manage** screens, press **F** to cycle through the filters available there. A chip in the header shows the active filter (`No filter`, then `Filter: <name>`). Keep pressing **F** to move to the next filter, or past the last one to go back to `No filter`.

Only filters whose **Show on** scope and **animal type** fit the current screen appear in the cycle - so you never have to scroll past filters that don't apply.

---

## Duplicate and delete

- **Duplicate** copies the selected filter, giving you a starting point for a variation.
- **Delete filter** removes it (with a confirmation).

---

## Multiplayer

Filters are shared across the whole server and are managed by the host. You need the **trade animals** farm permission to create, edit, or delete them, and your changes sync to everyone.

---

## Filters power the Herdsman

Every [Herdsman](guide-herdsman.md) rule points at one saved filter to decide which animals it acts on. If you plan to automate selling, moving, or buying, build the filter here first, then reference it from a rule.
