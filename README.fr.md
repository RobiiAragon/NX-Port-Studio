<p align="center"><img src="docs/images/hero.fr.svg" alt="NX Port Studio — Vos jeux Switch, en apps Apple natives" width="100%"></p>

<p align="center"><a href="README.md">English</a> · <a href="README.es.md">Español</a> · <strong>Français</strong> · <a href="README.ja.md">日本語</a> · <a href="README.zh-Hans.md">简体中文</a></p>

**Je développe NX Port Studio pour transformer vos propres fichiers de jeux Nintendo Switch en applications natives pour les plateformes Apple.** L'espace de travail macOS rassemble la préparation des ressources, la compilation, les contrôles et la signature des ports iPhone/iPad avec Xcode.

Je m’appuie sur [nxnative de seedds](https://github.com/seedds/nxnative) pour ce projet indépendant. Je préserve les crédits des auteurs du moteur et leurs avis de copyright : [crédits](CREDITS.md), [licence MIT](LICENSE).

> **1.6.0 RC7 :** j’ai corrigé la réception des sockets dans la mémoire suivie par le moteur graphique et la profondeur des pipelines préparés de Smash pendant mes essais de ports recompilés. J’ai mesuré environ 60 FPS dans une même scène d’entraînement de Smash, en fenêtre et en plein écran ; je n’ai pas encore validé de partie en ligne avec ce candidat. [Notes et limites du test](docs/releases/1.6.0-rc.7.md).

## Dans l'application

L’importation reconnaît ZIP/7z, les sous-dossiers et les extensions en majuscules, avec une extraction limitée et une vérification d’intégrité. Les erreurs connues proposent des étapes de résolution dans les cinq langues de l’interface.

L'interface démarre en espagnol. Son sélecteur propose aussi l'anglais, le français, le japonais et le chinois simplifié. La langue de l'interface et celle du jeu se règlent séparément.

![Création d'un port dans l'interface française](docs/images/fr/studio-new-port.jpg)

| Ressources du système | Découverte des salons locaux |
| :---: | :---: |
| [![Bibliothèque de ressources](docs/images/fr/studio-firmware.jpg)](docs/images/fr/studio-firmware.jpg) | [![Pont de découverte locale](docs/images/fr/studio-local-play.jpg)](docs/images/fr/studio-local-play.jpg) |

## Fonctionnalités

- Jeux de base, mises à jour et DLC dans un dossier par jeu, avec progression réelle et erreurs consultables.
- Exportations iOS signées par Xcode et vérifiées avant de signaler une réussite.
- Importation de vos ressources de firmware : modèles Mii, polices et certificats.
- J’ai ajouté une bibliothèque privée de Miis personnels dans **Micrologiciel → Importer des Miis**, distincte des modèles du micrologiciel. J’ai testé les formats, la persistance et l’intégration Mac/iOS avec des données synthétiques ; la vérification d’un Mii exporté de ma console dans un jeu reste à faire. Voir [formats et limites](docs/reference/services.md#personal-mii-imports-are-separate-from-firmware-model-archives).
- Mappage des contrôles, mouvement et vibrations selon les capacités du système et des manettes.
- Transport réseau natif, découverte LAN/LDN et intégration expérimentale de Nextendo.
- Configuration Nextendo depuis l’iPhone/iPad : navigateur du système, Trousseau de l’app et vérification des exigences du jeu et du service.

J’étends aussi le moteur : sockets Horizon, attentes HLE, vérification TLS, comptes et prise en charge des Joy-Con. La compatibilité dépend du jeu, de sa version et de l'appareil.

## État des essais

| Fonction | Résultat vérifié |
| --- | --- |
| LAN Mac ↔ Switch | J’ai terminé une course complète de Mario Kart 8 Deluxe 3.0.5 avec ma Switch physique et vérifié la création d’un salon dans un ancien candidat 3.0.5. Ces résultats sont historiques ; je n’ai pas répété ces essais avec mon candidat privé actuel 4.0.1. |
| LAN iPhone ↔ Switch | J’ai vérifié la participation au salon dans les deux sens, avec chaque appareil comme hôte. Je n’ai pas encore vérifié de course complète sur iPhone. |
| LDN / mode sans fil | Le 31 octobre, j’ai testé Mario Kart 3.0.5 en LAN et LDN entre les ports natifs Mac/iOS et ma Switch physique. Cela concerne les ports précédents ; je dois encore revalider le nouveau moteur. Le pont LDN IP exige un module compatible. |
| Mario Kart 8 Deluxe 4.0.1 | Je dispose d’un candidat Mac privé actuel et j’ai mesuré son rendu en plein écran dans le processus principal. Je n’ai pas terminé de course Nextendo ni revalidé le LAN/LDN physique avec ce candidat. |
| Smash 13.0.5 — Nextendo | J’ai vérifié le compte et **une manche réelle en arène sur Mac**, avec le certificat exact du service que j’ai autorisé. Le rejet des parties rapides pour réseau instable et une déconnexion ultérieure en spectateur restent ouverts ; je n’ai pas validé le jeu en ligne sur iOS. |
| Splatoon 2 EUR 5.5.2 — Nextendo | Le 2 novembre, j’ai atteint **le salon en ligne et la file Territorial sur Mac**, après le tutoriel et la place. J’ai reporté l’essai du match faute de joueurs disponibles en nombre suffisant. Je n’ai validé ni match terminé, ni jeu entre pairs, ni LAN/LDN, ni iOS pour ce titre. |
| Android / Windows | Je les prévois après la stabilisation des plateformes Apple ; je n’ai aucune version disponible. ARM et x86 nécessitent des travaux distincts. |

Les ports activent les services de connexion automatiquement. Choisissez En ligne, Sans fil local ou LAN dans le jeu, sans sélectionner un autre mode ni redémarrer. La configuration Nextendo reste indépendante : l’absence d’identifiants en ligne ne bloque pas le jeu local. La désactivation du réseau et l’adresse de découverte facultative restent dans les réglages avancés.

Pour le LAN, utilisez la même version du jeu et le même réseau local. Ce réseau peut fonctionner sans accès Internet. Le pont LDN sur IP exige un module compatible sur la console ; le mode LAN d'un jeu suit son propre protocole.

Mes essais TLS du 31 octobre ont relevé des négociations réussies et des erreurs de nom NEX ou de chaîne d’authentification encore ouvertes. Je conserve ces résultats et les contrôles de confiance non résolus échouent toujours. Mon candidat Mario Kart actuel est en **4.0.1** et satisfait l’exigence de version ; je n’ai pas qualifié ses chemins TLS/authentification, NAT ou une course en ligne. Les parties rapides et la stabilité des sessions Smash restent ouvertes. Dans Splatoon 2, deux connexions TLS vérifiées ont permis d’atteindre le salon et la file, sans valider un match ni le jeu entre pairs. Le [suivi de couverture](docs/nextendo-coverage.md) distingue mes résultats sur ces trois titres des 58 entrées, 62 profils régionaux et 22 plans de correctifs du catalogue.

## Démarrage

Il faut un Mac Apple silicon, macOS 14 ou ultérieur pour Studio, Xcode avec Swift 6 et vos propres fichiers de jeux et clés. Les ports iOS actuels ciblent iOS/iPadOS 26 et le matériel pris en charge. Certains jeux exigent une version plus récente de macOS/Metal.

Depuis le dépôt :

    cd macOS/NXPortStudio
    swift test
    swift run NXPortStudio

Dans Studio, préparez l'environnement, choisissez le dossier du jeu et prod.keys, puis sélectionnez Mac ou iPhone/iPad. Pour iOS, configurez votre équipe Xcode et un appareil associé. Un IPA est réussi seulement après signature et vérification ; les règles d'Apple sur les comptes et l'expiration s'appliquent.

Je conserve dans le dépôt les sources, les outils et mes captures de Studio. Les jeux, clés, firmwares, données de compte, sauvegardes et illustrations Nintendo restent hors du dépôt public.

Les ports Mac s’installent directement dans **Applications**. Le moteur temporaire, les fichiers extraits et les produits de compilation sont supprimés après la compilation, y compris en cas d’échec ou d’annulation. Les mises à jour vérifient la nouvelle app avant de remplacer le port du même jeu ; les sauvegardes et réglages sont conservés. Les projets iOS gardent leur flux de signature Xcode.

[Documentation complète en anglais](README.md) · [Feuille de route](ROADMAP.md) · [Contribuer](CONTRIBUTING.md)
