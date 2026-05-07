## Установка сервиса перенаправления (forwarding)

> [!WARNING]  
> Сервис перенаправления работает на промежуточном сервере

Сервис перенаправления позволяет проксировать входящие порты с промежуточного сервера на основной. IP адрес замените на IP адрес основного сервера (не домен! только IP адрес):

```bash
sudo ORIGIN_IP="IP_ADDRESS" bash -c "$(curl -sSL https://raw.githubusercontent.com/tihonme/kaska-d/main/forwarding_install.sh)"
```

<sup>Краткое описание: добавляет правила перенаправления.</sup>

## Удаление перенаправления

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/tihonme/kaska-d/main/forwarding_delete.sh)
```

<sup>Краткое описание: удаляет правила перенаправления. После удаления, чтобы изменения вступили в силу, перезапустите фаервол `ufw reload` и перезапустите систему `reboot`</sup>
