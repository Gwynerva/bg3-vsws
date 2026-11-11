"""Generate the mod's localization files for every language the game ships.

    python scripts/gen_loca.py

All of the mod's texts live here, in one table. Russian and English were
written by hand; the other languages are unreviewed translations - corrections
from native speakers are welcome.

The mode names are phrased as actions ("Always show"), like the game's own
helmet options, so they need no agreement with the gender of the slot name.
"""
import pathlib
from xml.sax.saxutils import escape

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / "mod/Mods/Gwynerva_VisibleShieldsAndWeaponSets/Localization"

# Text id -> handle. The order is the order of the columns in LABELS.
HANDLES = {
    # The four modes (button labels; option values in the controller popup).
    "Visible": "h153c3f7cga3aeg4d25gb8dcg439be99a27e1",
    "ActiveSet": "h02045512g42b3g4e65gbb80g2860f50b9145",
    "CinematicsHidden": "h4015e57fg601ag44eagac2fga543834139c8",
    "Hidden": "hb8aca5ffg5327g491eg9cd9gcfcde0e667bd",
    # Controller popup: the two options (they act on the weapon set in use).
    "MainHand": "hcc6fff75g71f5g42e0gbd4bg91c52dcf72c8",
    "OffHand": "h3e2ec6f9g6f2eg47d1ga3ebg827473b216c6",
}

# Folder name the game uses for the language -> texts in the order of HANDLES.
LABELS = {
    "English": ("Always show", "Show with current set", "Hide in dialogues", "Always hide",
                "Main hand weapon", "Off-hand weapon"),
    "Russian": ("Показывать всегда", "Показывать в текущем комплекте", "Скрывать в диалогах", "Скрывать всегда",
                "Оружие правой руки", "Оружие левой руки"),
    "Ukrainian": ("Показувати завжди", "Показувати в поточному комплекті", "Приховувати в діалогах", "Приховувати завжди",
                  "Зброя правої руки", "Зброя лівої руки"),
    "Polish": ("Zawsze pokazuj", "Pokazuj w bieżącym zestawie", "Ukrywaj w dialogach", "Zawsze ukrywaj",
               "Broń w głównej ręce", "Broń w drugiej ręce"),
    "German": ("Immer anzeigen", "Im aktuellen Set anzeigen", "In Dialogen verbergen", "Immer verbergen",
               "Haupthandwaffe", "Nebenhandwaffe"),
    "French": ("Toujours afficher", "Afficher avec l'ensemble actuel", "Masquer pendant les dialogues", "Toujours masquer",
               "Arme en main principale", "Arme en main secondaire"),
    "Italian": ("Mostra sempre", "Mostra con il set attuale", "Nascondi nei dialoghi", "Nascondi sempre",
                "Arma nella mano principale", "Arma nella mano secondaria"),
    "Spanish": ("Mostrar siempre", "Mostrar con el conjunto actual", "Ocultar en los diálogos", "Ocultar siempre",
                "Arma de la mano principal", "Arma de la mano secundaria"),
    "LatinSpanish": ("Mostrar siempre", "Mostrar con el conjunto actual", "Ocultar en los diálogos", "Ocultar siempre",
                     "Arma de la mano principal", "Arma de la mano secundaria"),
    "BrazilianPortuguese": ("Mostrar sempre", "Mostrar com o conjunto atual", "Ocultar nos diálogos", "Ocultar sempre",
                            "Arma da mão principal", "Arma da mão secundária"),
    "Turkish": ("Her zaman göster", "Geçerli sette göster", "Diyaloglarda gizle", "Her zaman gizle",
                "Ana el silahı", "Diğer el silahı"),
    "Chinese": ("始终显示", "当前套装时显示", "对话时隐藏", "始终隐藏", "主手武器", "副手武器"),
    "ChineseTraditional": ("一律顯示", "目前套裝時顯示", "對話時隱藏", "一律隱藏", "主手武器", "副手武器"),
    "Japanese": ("常に表示", "現在のセットで表示", "会話中は非表示", "常に非表示", "メインハンド武器", "オフハンド武器"),
    "Korean": ("항상 표시", "현재 세트일 때 표시", "대화 중 숨김", "항상 숨김", "주 손 무기", "보조 손 무기"),
}


def main():
    for language, texts in LABELS.items():
        if len(texts) != len(HANDLES):
            raise SystemExit(f"{language}: {len(texts)} texts, expected {len(HANDLES)}")
        rows = "\n".join(
            f'    <content contentuid="{handle}" version="1">{escape(text)}</content>'
            for handle, text in zip(HANDLES.values(), texts)
        )
        path = OUT / language / "Gwynerva_VisibleShieldsAndWeaponSets.xml"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(
            f'<?xml version="1.0" encoding="utf-8"?>\n<contentList>\n{rows}\n</contentList>\n',
            encoding="utf-8", newline="\n")
    print(f"wrote {len(LABELS)} languages x {len(HANDLES)} texts to {OUT.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
