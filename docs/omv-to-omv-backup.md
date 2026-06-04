# Backing up one OMV server to another with BorgBackup

This guide walks you through setting up an **automatic, encrypted, ransomware‑resistant
backup from one OpenMediaVault server to another**, using the BorgBackup plugin's
**Serve** feature.

You will use two machines:

| Role | What it does | What you configure |
|------|--------------|--------------------|
| **Backup server** | Stores the backups. Hosts the repository. | The **Serve** tab |
| **Backup client** | The server whose data you want to protect. Pushes backups out. | The **Repos** + **Archives** tabs |

> **Tip:** "append‑only" mode (enabled by default in this guide) means that even if the
> client is hacked or hit by ransomware, the attacker **cannot delete or alter the
> backups already stored on the backup server**. This is the single biggest reason to
> back up OMV‑to‑OMV this way.

Both machines need the **openmediavault‑borgbackup** plugin installed (version 8.2 or
later, which adds the Serve tab).

---

## Part 1 — On the BACKUP SERVER (the destination)

This is the machine that will *receive and keep* the backups.

### Step 1.1 — Enable SSH

1. Go to **Services → SSH**.
2. Tick **Enable** and **Save / Apply**.

The backup client will connect to this machine over SSH.

### Step 1.2 — Create a user for the backup client to log in as

You can reuse an existing user, but a dedicated one is cleaner.

1. Go to **Users → Users → Create**.
2. Name it something like `borgserve`.
3. Give it a password (it won't be used for backups, but OMV requires one).
4. **Save**.

### Step 1.3 — Create a shared folder to hold the backups

1. Go to **Storage → Shared Folders → Create**.
2. Name it e.g. `borg-backups` and pick the disk/pool with room to store backups.
3. **Save**.
4. Select the folder, click **Permissions**, and give your `borgserve` user
   **read/write** access. (Borg needs to create and write repository files here as
   that user.)

### Step 1.4 — Add the client on the Serve tab

1. Go to **Services → BorgBackup → Serve → Create**.
2. Fill in the form:
   - **Name** — a label for this client, e.g. `office-nas`.
   - **Login user** — select `borgserve`.
   - **Target shared folder** — select `borg-backups`. The client will be *locked
     into this folder* and cannot see anything else on the server.
   - **Append‑only** — leave **ticked** (recommended).
   - **Storage quota** — optional, e.g. `500G` to cap how much this client can store.
     Leave blank for no limit.
   - **Client public key** — you have two choices:
     - **Easiest:** leave it **blank**. The plugin will generate a key pair for you.
     - **Or** paste the client's existing public key (see the alternative in Part 2).
3. Click **Save**, then **Apply** the pending configuration change.

### Step 1.5 — Download the private key (only if you left the key blank)

If you let the plugin generate the key:

1. Back on the **Serve** list, select your new `office-nas` row.
2. Click **Download private key** (the download icon).
3. Save the file — you'll move it to the backup client in Part 2.

> The **Private key stored** column shows a check mark for clients whose key was
> generated here and can be downloaded. Keep this file safe; treat it like a password.

The backup server is now ready and listening. Note down:

- the server's **hostname or IP address**
- the **login user** (`borgserve`)
- the **full path of the target shared folder** — find it under
  **Storage → Shared Folders** (e.g. `/srv/dev-disk-by-uuid-xxxx/borg-backups`)

---

## Part 2 — On the BACKUP CLIENT (the source)

This is the machine whose data you want to protect.

### Step 2.1 — Put the private key on the client

The BorgBackup plugin runs as **root**, so the key must be readable by root.

1. Copy the private key you downloaded to the client, for example to
   `/root/.ssh/borg_omv`.
2. Set tight permissions (from **System → … →** a root shell, or `! ` in the OMV
   command box):

   ```bash
   install -m 600 /path/to/downloaded-key /root/.ssh/borg_omv
   ```

> **Alternative (key never leaves the client):** instead of generating the key on the
> server, generate it here with `ssh-keygen -t ed25519 -f /root/.ssh/borg_omv`, then
> paste the contents of `/root/.ssh/borg_omv.pub` into the **Client public key** field
> back in Step 1.4. This way the private key never travels between machines.

### Step 2.2 — Tell Borg which key and host to use

1. Go to **Services → BorgBackup → Environment Variables → Create**.
2. Add:
   - **Name:** `BORG_RSH`
   - **Value:** `ssh -i /root/.ssh/borg_omv -o StrictHostKeyChecking=accept-new`
   - **Repo:** you can set this after creating the repo in the next step, or choose
     **Repo creation** for now and revisit.
3. **Save**.

This tells Borg to connect using your key and to trust the server's host key on first
connection.

### Step 2.3 — Create the remote repository

1. Go to **Services → BorgBackup → Repos → Create**.
2. Fill in:
   - **Name** — e.g. `offsite`.
   - **Type** — **Remote**.
   - **Remote path** — this points at a *new sub‑folder inside the server's target
     shared folder*. Use the form:

     ```
     borgserve@SERVER-HOST:/srv/dev-disk-by-uuid-xxxx/borg-backups/office-nas
     ```

     Replace `SERVER-HOST` with the server's hostname/IP and the path with the target
     shared folder path you noted in Part 1, plus a repo name on the end
     (`office-nas` here).
   - **Passphrase** — set a strong passphrase. **Write it down somewhere safe** — without
     it your backups cannot be restored.
   - **Encryption** — tick it (recommended).
   - **Skip init** — leave unticked (this is a brand‑new repo).
3. Make sure your `BORG_RSH` environment variable from Step 2.2 is attached to this
   repo (edit it and set **Repo** to this repo if you used "Repo creation" earlier).
4. **Save**. The plugin will create (initialise) the repository on the backup server.

> If this step fails with a connection or permission error, jump to **Troubleshooting**
> below.

### Step 2.4 — Create a backup archive (what to back up, and when)

1. Go to **Services → BorgBackup → Archives → Create**.
2. Fill in:
   - **Name** — e.g. `daily`.
   - **Repo** — select the `offsite` repo.
   - **Include** — the folders to back up, one per line (e.g. `/srv/dev-disk-by-uuid-yyyy/data`).
   - **Exclude** — anything to skip (optional).
   - **Schedule** — pick a time, e.g. **Daily at 03:00**.
   - Compression and other options can be left at their defaults.
3. **Save** and **Apply**.

### Step 2.5 — Run it once to confirm

1. Select the `daily` archive and click **Backup** (you can tick *dry run* first to test
   without writing data).
2. Watch the live output. A successful run ends with backup statistics.

Your OMV‑to‑OMV backup is now running automatically on the schedule you set. 🎉

---

## Pruning and housekeeping (important with append‑only)

Because the client connects in **append‑only** mode, it can *add* backups but **cannot
delete old ones** — that's what protects you from ransomware. Old backups are therefore
removed and space reclaimed **from the backup server side**:

- On the **backup server**, go to **Services → BorgBackup → Compact** and schedule a
  periodic compaction of the `borg-backups` repository to reclaim freed space.
- Retention (how many daily/weekly/monthly backups to keep) is configured per archive on
  the **client**, but the actual deletion is honoured on the server during compaction.

---

## Troubleshooting

**"Connection refused" / "Permission denied (publickey)"**
- Confirm SSH is enabled on the backup server (Step 1.1).
- Confirm the private key path in `BORG_RSH` is correct and the file is `chmod 600`.
- Confirm the public key matches the client entry on the server's Serve tab.

**"borg: command not found" over SSH**
- The BorgBackup plugin must be installed on the **backup server** too — the forced
  `borg serve` command runs there.

**"Repository path not allowed" / restrict‑to‑path errors**
- The **Remote path** in Step 2.3 must be *inside* the target shared folder you chose on
  the Serve tab. Check the path matches exactly.

**Permission denied writing the repository**
- The Serve **Login user** needs read/write permission on the target shared folder
  (Step 1.3, Permissions).

**Where did the access actually get configured?**
- On the backup server, each Serve client becomes a single restricted line in the login
  user's `~/.ssh/authorized_keys`, for example:

  ```
  command="borg serve --restrict-to-path '/srv/.../borg-backups' --append-only",restrict ssh-ed25519 AAAA... office-nas
  ```

  This is what confines the client to `borg serve`, locks it to one folder, and enforces
  append‑only. Do **not** also add the client's key to that user's profile under
  **User Management**, or the restriction could be bypassed.
