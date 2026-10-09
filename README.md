# vps-grapevine

How about your host has a demon thats a LLM running on French Cloud in French Data Centers like 

Run opencode on a rented VPS (or anything that is Linux) and drive it from your laptop over an SSH
tunnel—the service binds to loopback only, so nothing new faces the internet, and nftables drop as belt-and-braces.

```
your mac ──ssh:22──▶ VPS ──▶ opencode-serve.service (127.0.0.1:4096)
        ◀── forwarded 4096 ──┘   opencode attach http://127.0.0.1:4096
```

The idea is to use the stock cloud image with the stock cloud firewall and basic backups, plus security updates and nearby affordances like weekly backups. If you want old-school EC2 or bare metal, you do you! 

On top of that, we have vines and grapes for setting up Traefik and Docker Compose.  

The idea here is that all the user-facing code is in docker. The underlying box is only visible over port 22. The host has no userland. This means I use old-school big-boys rules to run as root; the sandbox IS the VPS. That relies on backups, DNS, and the like, with no secrets on any host that let it control anything beyond the docker images on the host. 

Secrets need some concept of a vault; this project uses git-veil, inspired by git-secret but using `age` for encryption. The idea is you use this repo as a template to make your own logic environment dev|test|prod where there is a set of shared secrets of the resources used by the servers in the environment. 

## Official install path

1. **Install opencode from the release page** of the opencode site.
   Never pipe the installer into a shell
   (`curl -fsSL https://opencode.ai/instaII | bash` as it is too dangerous, hence the deliberate typo!).

   Be a hero and check the SHAs on the binaries before you install them.

   Note: the idea is that you SSH in once to verify that it works with:

           opencode --mini

   If you don't use mini mode, the full-fat TUI is stunningly heavy on CPU for some reason; hence the mini mode. The good news is that when it runs a WS server, it takes very few resources, as you run the beautiful TUI on your laptop and connect via an SSH tunnel (see below).  
   
3. **Auth on the CLI (v2):**

   OpenCode TUI can work with any number of providers like Anthropic, OpenAI or Mistral AI, or their OpenCode Go or OpenCode Zen services.

   The big idea of this repo is that you can get a Mistral AI key, log in, and use Sans USA. Mistral AI is now hosting Z.ai models, which are IMHO ready for "prime time". 

   If you wanna use a model hosted by the company behind opencode in the USA, great for experimenting, try:

       opencode auth login opencode

   The v1 command `opencode console login` did not work — use the v2
   command above. Then run `/models` and select a model.

   You **must** set up quota and keys, ideally a key per host and the like, to ensure it does not eat your wallet.

## Box setup (after installing opencode TUI)

The unit lives at locations such as `server/opencode-serve.service.ubuntu`, which is a service to run 
`opencode serve` to bind WebSockets to localhost. Install it on
the box (root):

    install -m 644 opencode-serve.service.${distro} /etc/systemd/system/opencode-serve.service
    systemctl daemon-reload
    systemctl enable --now opencode-serve.service

Note that means it starts by default; if you want to turn that off on prod, you ssh in and disable it so that you have to start it up and shut it down. 

It binds `127.0.0.1:4096` only — nothing on the public interface; configure any 
cloud firewall for openssl letsencrypt on 22/80/443, and nothing else opens. Auth is direct
(v2 auth above); no proxy legs, no daemon, no ACP.

## Attach from your laptop

Now, the magic install: you SSH your key into the host and then set up a tunnel in one laptop terminal:

    ssh -N -L 4096:127.0.0.1:4096 root@<box-host>

Then, in a second startup opencode TUI to connect to the demon running on your VPS host:

    opencode attach http://127.0.0.1:4096

Sessions persist server-side in the opencode db, so reconnect + attach resumes. 

## What is on this grapevine? 

| Path | Purpose |
|---|---|
| `server/opencode-serve.service.ubuntu` | the systemd unit (loopback-only headless serve) |
| `server/SETUP-NOTES.md.secret` | private runbook via git-veil (reveal with git-veil) |
| `grapes/` | containers living on the boxes: Forgejo, Traefik, Zitadel, OpenResty sidecar |
| `server/backup-sweep.sh` + `backup-sweep.conf.example` + `backup-to-scaleway.sh`/`backup-to-s3.sh` | box backup contract: nightly sweep (bundles+fileset tars to /opt/backup) + age-encrypted S3 uploader; S3 creds read at runtime from the git-veil vault |
| `server/nftables/` | firewall configs for the boxes |
| `docs/` | estate runbooks: DNS segregation, cloud firewall, SEV0 access loss, box policy templates |

## Releases

Tags are immutable, releases are disposable. No release is cut for
config changes.
