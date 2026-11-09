# Connecting to Your Server

Luma Music connects to an OpenSubsonic-compatible server for playback.

## You need

- A server address such as `https://music.example.com`
- A username and password
- The OpenSubsonic API enabled on the server

## Connect

1. Open **Settings → Account → Server** and enter the address.
2. Enter the account details and verify the connection.
3. Albums and playlists on Home confirm the connection.

## Troubleshooting

- Do not append `/rest`; Luma handles the API path.
- Servers using a self-signed certificate may need a trust configuration on iOS.
- Check that a VPN or firewall is not blocking API requests.
- Server passwords and tokens stay in the device Keychain and are never sent to GitHub.
