# rex-file-paste

Collez les fichiers du presse-papiers du Mac dans un pane [Rex](https://www.superlogical.com/rex), sous forme de chemins. Si le pane tourne sur un autre serveur Rex, le module copie d'abord les fichiers sur cette machine.

Le module remplace [rex-image-paste](https://github.com/pablasso/rex-image-paste), dont il reprend le mécanisme de transfert. Une seule touche sert pour les images et pour les documents.

## Utilisation

1. Copiez un ou plusieurs fichiers dans le Finder (<kbd>Cmd</kbd>+<kbd>C</kbd>), ou faites une capture d'écran vers le presse-papiers.
2. Dans un pane Rex, appuyez sur <kbd>Cmd</kbd>+<kbd>Maj</kbd>+<kbd>V</kbd>.
3. Le module colle les chemins, séparés par une espace.

Sans fichier ni image dans le presse-papiers, la touche ne fait rien. <kbd>Cmd</kbd>+<kbd>V</kbd> colle le texte comme avant.

Le module colle seulement du texte. Il ne dépend d'aucun agent. Il ne convertit pas les documents : un agent qui reçoit le chemin d'un `.docx` ou d'un `.xlsx` doit avoir un outil pour lire ce format.

## Fonctionnement

- **Pane sur le Mac.** Le module colle le chemin d'origine. Il ne copie rien. Une image brute du presse-papiers (capture d'écran) est enregistrée dans `$TMPDIR/rex-file-paste/`, puis son chemin est collé. Ce fichier est supprimé après un jour.
- **Pane sur un autre serveur.** Le module copie chaque fichier vers `/tmp/rex-file-paste-<uid>/<hash>/<nom d'origine>`. `<hash>` vient du SHA-256 du contenu. Un fichier déjà présent avec le même contenu n'est pas renvoyé.
- **Chemins.** Les chemins collés sont protégés pour le shell, comme quand vous déposez un fichier dans un terminal : une barre oblique inverse précède chaque espace, apostrophe ou parenthèse (`Rapport\ d\'été.pdf`). Les lettres accentuées restent telles quelles. Le nom copié est en forme Unicode composée (NFC).
- **Images.** Avant une copie, le module convertit en PNG les formats que les agents ne lisent pas (HEIC, TIFF, BMP). Il réduit les images dont le grand côté dépasse 2000 px. Les autres fichiers sont copiés sans modification.
- **Nettoyage.** À chaque collage vers un serveur, les fichiers de plus d'un jour sont supprimés, avec les dossiers de hash vides. Le dossier distant a le mode 0700.

### Transfert

1. L'action `file_paste` tourne dans le serveur Rex du Mac. Elle lit le presse-papiers avec `osascript` (JXA, `NSPasteboard`) et contrôle les fichiers.
2. Rex arrête une action de configuration après 30 secondes. Pour un pane distant, l'action écrit donc un fichier de tâche et lance un processus `rex do worker.lua` détaché. Puis elle rend la main. Un script `rex do` n'a pas de limite de durée.
3. Le worker ouvre un terminal caché sur le serveur distant. Ce terminal lance `sh` avec un script fixe. Les noms de fichier arrivent en arguments, jamais dans le texte du script. Le terminal passe en mode raw et lit le fichier en base64 avec `head -c N | base64 -d`.
4. Le worker envoie le base64 par requêtes `block.method write` de 63 KiB. Rex refuse une requête de plus de 64 KiB.
5. Le serveur distant renvoie le SHA-256 du fichier. Le worker le compare à celui du Mac.
6. Le worker colle les chemins par un événement `paste` (bracketed paste).

Le serveur distant a besoin de `sh`, `base64`, `head`, `sha256sum` (ou `shasum`) et `find`. Il n'a pas besoin de SSH.

### Progression

Quand une copie dure plus de 2 secondes, le module ouvre une petite couche flottante en bas de la fenêtre du pane. Elle affiche une barre de progression. Le programme de cette couche signale aussi le pourcentage par la séquence OSC 7501 (protocole d'état des programmes de Rex). La couche se ferme à la fin de la copie, et elle ne prend pas le focus.

## Installation

Sur le Mac, clonez le dépôt à côté de votre `init.lua` Rex. Le fichier est `$REX_CONFIG`, sinon `~/.config/rex/init.lua` (vérifiez avec `rex config check`).

```sh
mkdir -p ~/.config/rex
git clone https://github.com/PaulM5406/rex-file-paste ~/.config/rex/rex-file-paste
```

Ajoutez cette ligne à `~/.config/rex/init.lua` :

```lua
require("rex-file-paste").setup{ max_size_mb = 25, max_dimension = 2000, key = "cmd+shift+v" }
```

Si vous utilisez rex-image-paste, supprimez ses deux lignes (`require("rex-image-paste").setup()` et `rex.bind("cmd+shift+v", "image_paste")`).

Rechargez la configuration :

```sh
rex config check
rex config reload
```

Rex charge les modules depuis le dossier de l'`init.lua` qu'il ouvre. Si `init.lua` est un lien symbolique, clonez à côté du lien.

## Options

| Option | Défaut | Description |
| --- | --- | --- |
| `key` | `"cmd+shift+v"` | Touche liée à l'action `file_paste`. `false` : aucune liaison. |
| `max_size_mb` | `25` | Taille totale maximale, en Mio, d'une copie vers un autre serveur. |
| `max_dimension` | `2000` | Grand côté maximal d'une image copiée, en pixels. `false` : taille gardée. |
| `convert_images` | `true` | `false` : les images sont copiées sans conversion ni réduction. |
| `timeout` | `15` | Secondes ajoutées au délai d'abandon. |
| `min_rate_mb` | `0.5` | Débit minimal supposé, en Mio/s. Délai d'abandon = `timeout` + taille / `min_rate_mb`. |
| `progress_after` | `2` | Secondes de copie avant l'affichage de la progression. |
| `notify` | `true` | Notification macOS si une copie en arrière-plan échoue. |
| `local_dir` | `$TMPDIR/rex-file-paste` | Dossier du Mac pour les tâches, les images et le journal `worker.log`. |
| `rex_path` | trouvé seul | Exécutable `rex` qui lance le worker. |

## Limites

- **Taille.** Une copie de plus de `max_size_mb` (25 Mio par défaut, total des fichiers) est refusée. Rien n'est collé. La limite ne s'applique pas à un pane local, car rien n'est copié.
- **Débit.** Mesuré vers un serveur Linux par Tailscale : environ 1,8 Mo/s, soit 11 s pour un fichier de 20 Mo. Le débit dépend de la latence, car chaque requête attend sa réponse.
- **Dossiers.** Un dossier est refusé, avec un message. Copiez les fichiers qu'il contient.
- **Noms.** Un nom qui contient un caractère de contrôle (saut de ligne, tabulation, etc.) est refusé.
- **Plusieurs fichiers.** Si un seul fichier est refusé, aucun n'est collé.
- **Image du Finder dans un pane local.** Le module colle le chemin d'origine, sans conversion. Exemple : un `.heic` reste un `.heic`. La conversion s'applique seulement aux copies et aux images brutes du presse-papiers.
- **Erreurs.** Une erreur de l'action (refus, dossier, nom) est renvoyée à Rex, qui l'affiche. Une erreur du worker (copie, somme de contrôle, délai) apparaît dans une notification macOS et dans `worker.log`.
- **Mac seulement.** L'action doit tourner dans le serveur Rex du Mac, car elle lit le presse-papiers du Mac.

## Test

Le test utilise un presse-papiers privé nommé. Il ne touche pas au vôtre.

```sh
rex do test/e2e.lua                          # tous les cas, pane local
rex do test/e2e.lua host=LABEL               # tous les cas, pane sur un autre serveur
rex do test/e2e.lua host=LABEL kind=big      # un seul cas
```

Cas : `pdf`, `docx`, `name`, `two`, `big`, `over`, `text`, `folder`, `ctrl`, `tab`, `image`, `heic`, `cleanup`. Le test compare le SHA-256 de chaque fichier source et du fichier collé, après lecture du texte collé par `sh` et `bash` (distant) ou `sh` et `zsh` (local). Il ferme ses terminaux, détruit sa session distante et supprime ses fichiers à la fin.

## Désinstallation

1. Supprimez la ligne `require("rex-file-paste").setup{...}` de `~/.config/rex/init.lua`.
2. Rechargez : `rex config reload`.
3. Supprimez le module : `rm -rf ~/.config/rex/rex-file-paste`.
4. Supprimez les fichiers temporaires du Mac : `rm -rf "$TMPDIR/rex-file-paste"`.
5. Sur chaque serveur distant, supprimez les copies : `rm -rf /tmp/rex-file-paste-$(id -u)`.

## Licence

MIT. Dérivé de rex-image-paste de Pablo Ortiz (pablasso), sous licence MIT. Voir `LICENSE`.
