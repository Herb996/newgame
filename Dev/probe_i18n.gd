extends SceneTree
## 临时诊断：确认翻译资源加载与 locale 生效情况
func _init() -> void:
	print("locale(before)=", TranslationServer.get_locale())
	TranslationServer.set_locale("en")
	print("locale(after)=", TranslationServer.get_locale())
	print("translate 新建存档 -> ", TranslationServer.translate("新建存档"))
	quit()
