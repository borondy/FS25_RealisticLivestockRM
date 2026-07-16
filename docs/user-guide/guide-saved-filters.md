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

## Adding conditions

With a filter selected, press **Add condition**. A small dialog asks for three things:

- **Field** - what to test (Age, Gender, a genetics trait, Breed, and so on).
- **Compare** - how to test it (equals, is at least, is less than, contains, is one of, ...).
- **Value** - what to match against.

For example, Field **Age**, Compare **is at least**, Value **30** shows up in the list as `Age >= 30`. Each condition becomes a row; select a row to **Edit** or **Delete** it.

A few things worth knowing:

- **Genetics are shown on a 0-99 scale** - the same number you see on the animal's info card. `Genetics (overall) >= 75` does what you'd expect.
- **Yes/no fields** (pregnant, castrated, has a disease, ...) are matched as true or false.
- **Text fields** (the animal's name) match by "contains" / "does not contain", and are not case-sensitive.

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
