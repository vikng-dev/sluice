# The panel

Each profile's accounts sit on a card under its name, a pool per provider.

- **An account** is two lines: who it is (its address, whether a client is itself signed in as it,
  its plan), and its week as a bar with the share used and the time until it resets. Where another
  of its limits is fuller than its week and near its end, such as its five hours or one model's own
  share of the week, the bar is that one's, named. Left of an account that answered within the last
  minute, three green bars flicker low; while it is
  at work on requests they are a level meter, struck higher and oftener the more of them there are,
  up at once and falling back slowly.
- **A click on an account** lists every limit it has, and under them the resets it holds. Each is a
  chip saying what it refills and how long until it lapses; a click on a chip and then on the red
  check beside it uses it, which cannot be taken back.
- **A pool's header** says how much of the pool is used, as [How a pool is counted](routing.md#how-a-pool-is-counted)
  says. Its star puts the pool in the menu bar as its provider's mark and its share, a profile's pools
  together after a short bar in the profile's color, in place of the glyph while the clients are routed.
- **A click on any share** reads them all as left, and on any clock reads them all as the time itself.
- **What can be done to a thing shows when the pointer is on it.** A profile's **+** adds an account
  to it, at the provider you pick, or work that belongs to it (folders, or a repository owner), and
  removes the profile. An account is removed by its bin. Removing waits for a red check where it is,
  beside a cross that leaves it.
- **An account is moved by its handle**: it lifts off the panel and drops onto another profile, or
  onto **New profile** to get a profile of its own, named from its address unless you type another.
- **A profile's name and color dot** are changed where they are: click the name to type another,
  click the dot to pick a color. Beside the name is a count of the folders and repository owners
  whose work the profile claims; click it to lay them out, each let go by the × it shows under the
  pointer. The default profile has everything else.
- **New profile**, after the last profile, is typed in place: what you type is what it is shown as,
  its name is made from it, and the check after it makes it.
- **A repository owner** is typed under the profile's name. While it is typed, the ones offered are
  those of the repositories the clients have worked in on this Mac, and then the accounts GitHub's
  public search finds for the letters typed, which are all that is sent to it. A click on one claims it.
- **The first line** holds the panel's three views: the accounts, their use, and the settings.
- **The second view** is the last seven days of use. Each pool has a bar for every day: how much of
  the pool that day used, in the colors of the accounts that gave it, against a dashed line at the
  pace that uses the pool up in a week, a seventh of it a day. Over the bars is how much went in the last 24 hours, and
  when the pool runs dry at that rate if it does. Under the profiles, the tokens of each hour and
  where they went by folder and by model. Whatever the pointer is on says more beside it: a day's
  share by account, an hour's tokens, a folder's path and share.

- **The third view** is the settings, each holding at once. The [status line](status-line.md) with its switch, and while it is on, as it
  would read over its items: a click takes one off or puts one on, and one is dragged to where
  it is said. Whether the clients go through Sluice. The bolt, which has Sluice use resets
  for you, as [How an account is picked](routing.md) says. The version, and **Quit**.

The panel also says when the clients are not going through Sluice. `sluice status` prints the same accounts.
