# Releasing Immersive First Person

Publishing a GitHub release uploads the corresponding source revision to the existing Nexus Mods page. Creating a tag by itself does not publish anything.

## One-time setup

1. Create a [Nexus Mods API key](https://www.nexusmods.com/settings/api-keys).
2. Add it as the `NEXUSMODS_API_KEY` [GitHub Actions repository secret](https://github.com/cp2077/ImmersiveFirstPerson/settings/secrets/actions).
3. On the Nexus [Files page](https://www.nexusmods.com/cyberpunk2077/mods/2675?tab=files), open **API Info** for the main **Immersive First Person** file and copy its Group ID.
4. Add that Group ID as `NEXUSMODS_FILE_ID` in [GitHub Actions repository variables](https://github.com/cp2077/ImmersiveFirstPerson/settings/variables/actions). The pinned Nexus action calls this input `file_id`, but it identifies the persistent file group rather than an individual uploaded version.
5. Look up the Nexus v3 Mod ID for the public Cyberpunk 2077 mod number `2675`:

   ```powershell
   $secureKey = Read-Host 'Paste the Nexus API key' -AsSecureString
   $apiKey = [Net.NetworkCredential]::new('', $secureKey).Password
   $response = Invoke-RestMethod `
       -Uri 'https://api.nexusmods.com/v3/games/cyberpunk2077/mods/2675' `
       -Headers @{ apikey = $apiKey }
   $response.data.id
   Remove-Variable apiKey, secureKey
   ```

6. Add the returned ID as `NEXUSMODS_MOD_ID` on the same GitHub repository variables page.

## Publish a version

1. Set the version in `init.lua`, using stable semantic versioning such as `2.0.0`.
2. Run `.dev/check.ps1` and test the release candidate in game.
3. Commit and push the exact revision to release.
4. Open [Draft a new GitHub release](https://github.com/cp2077/ImmersiveFirstPerson/releases/new).
5. Create a matching tag with a `v` prefix, such as `v2.0.0`.
6. Use a release body with exactly one short paragraph followed by a `## Changelog` section:

   ```markdown
   Complete 2.0 rewrite with improved body visibility, safer FreeLook input, and camera-conflict detection.

   ## Changelog

   - Reworked first-person camera positioning.
   - Removed the options.json override requirement.
   - Added mouse and controller FreeLook support.
   ```

7. Publish the GitHub release when the notes and tag are final.

The first paragraph becomes the Nexus file description and must not exceed 255 characters. The changelog section is submitted through the Nexus changelog API. The uploaded archive is named `Immersive First Person.zip`, its Nexus display name is `Immersive First Person`, the Nexus mod version is updated to match the release, and the previous file version is not archived.
