# Chest Tracker

Compteur de coffres animé pour Fortnite, à lancer pendant que tu joues.

- Animation à chaque coffre ouvert (pièces, gemmes, rayon de lumière)
- Compteur, objectif avec anneau de progression, stats de session, historique
- Touches globales en jeu (par défaut **F8** = +1, **F7** = annuler), modifiables dans les réglages
- Fenêtre toujours au premier plan (Fortnite en « Plein écran fenêtré »)
- Aucun son

## Utilisation

Double-clique sur `ChestTracker.bat`. Le menu permet de changer l'objectif, définir le nombre de coffres déjà ouverts, reset la session ou arrêter le tracker.

## Structure

- `ChestTracker.bat` : fichier unique à lancer (contient le serveur et l'interface)
- `src/head.bat` : menu et lanceur
- `src/tracker.ps1` : serveur local (127.0.0.1:47821) + raccourcis globaux
- `src/tracker.html` : interface

`ChestTracker.bat` = `head.bat` + `:::PS1:::` + `tracker.ps1` + `:::HTML:::` + `tracker.html` (fins de ligne CRLF).
