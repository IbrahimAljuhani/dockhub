# 🏠 Home-Automation

Running your home — lights, sensors, switches, and the messaging layer they talk over.

| | Role |
|---|---|
| ✅ [**Home Assistant**](home-assistant/) | The **hub**. Devices, automations, dashboards, and integrations for thousands of products. |
| ✅ [**Eclipse Mosquitto**](mosquitto/) | The **MQTT broker** — the messaging layer most sensors and DIY devices speak. |

---

## 📌 How they fit together

They aren't alternatives; they're layers. Home Assistant is what you look at. Mosquitto is what your devices publish to, and Home Assistant subscribes.

You need Mosquitto if you have MQTT devices — ESP boards, Zigbee bridges, many DIY sensors. If every device you own has a native Home Assistant integration, you can skip it.

---

## 📌 Things worth knowing

**Home Assistant uses host networking**, unlike every other service here. It needs it to discover devices on your LAN by broadcast, so its port `8123` is always bound to the host rather than being an opt-in prompt.

**Mosquitto has no web interface at all.** MQTT is a protocol, not a website — there's nothing to point NGINX Proxy Manager at. Because "container started" tells you nothing in that situation, its `deploy.sh` performs a real publish/subscribe round trip after starting and reports whether the broker actually accepted a connection.

**Mosquitto 2.x refuses remote connections by default.** A stock config only listens on localhost, which looks like a broken deployment. This deployment configures a proper listener and a password file — that's a deliberate deviation, not an accident.

---

← Back to [all services](../README.md)
