"""Catalog genres — sections of our own release list, merged into understandable ones.

The source list has 289 music sections, and every genre doubles in them: lossless and
lossy, separately "digitizations" and Hi-Res. A person does not need that — they need "Jazz",
not five jazz sections. The table is manual: a section does not change for years, and
a rule on words in the section name would confuse "Folk-Rock" with "Folk Metal".

They go nowhere, and that is a decision, not forgetfulness: radio shows and mixes (there is no
artist), label packs and unofficial compilations, AI music, karaoke and
backing tracks, SACD and Dolby Atmos conversions (the phone cannot play them), "music of other
genres". Section names come from the source's category tree, 19.09.2026.
"""

from __future__ import annotations

GENRES: tuple[tuple[str, str, tuple[int, ...]], ...] = (
    # Rock
    ("classic-rock", "Классический и хард-рок", (1698, 1702, 1703, 2329, 2330, 731, 1799, 1755, 1756)),
    ("prog-rock", "Прогрессив и арт-рок", (1704, 1705, 1757)),
    ("folk-rock", "Фолк-рок", (1706, 1707)),
    ("pop-rock", "Поп-рок и софт-рок", (1708, 1709)),
    ("guitar-rock", "Инструментальный гитарный рок", (1710, 1711)),
    ("rockabilly", "Рокабилли и рок-н-ролл", (1712, 1713)),
    ("asian-rock", "Азиатский рок", (1714, 1715)),
    ("alternative", "Альтернатива и ню-метал", (1736, 1737, 1396)),
    ("punk", "Панк и хардкор", (1738, 1739)),
    ("indie", "Инди и брит-поп", (1773, 202, 123)),
    ("post-punk", "Пост-панк и шугейз", (172, 236)),
    ("post-rock", "Пост-рок", (1742, 1743)),
    ("metalcore", "Металкор и пост-хардкор", (1746, 1747)),
    ("gothic-rock", "Готик-рок и дарк-фолк", (1748, 1749)),
    ("experimental-rock", "Экспериментальный рок и метал", (2175, 2174, 1796, 1797)),
    ("industrial", "Индастриал", (1744, 1745, 1877, 1878)),
    ("russian-rock", "Русский рок", (737, 738, 951, 952, 1758)),
    ("russian-alternative", "Русская альтернатива и панк", (464, 463)),
    ("russian-metal", "Русский метал", (739, 740)),
    # Metal
    ("heavy-metal", "Хэви, пауэр и прогрессив-метал", (1726, 1727, 1890, 1766)),
    ("thrash-metal", "Трэш и спид-метал", (1728, 1729)),
    ("death-metal", "Дэт, дум и грайнд", (1779, 1780, 1730, 1731)),
    ("black-metal", "Блэк-метал", (1719, 1778)),
    ("folk-metal", "Фолк и пейган-метал", (1720, 798)),
    ("gothic-metal", "Готик-метал", (1724, 1725)),
    ("stoner", "Стоунер, сладж и пост-метал", (1815, 1816)),
    # Pop
    ("pop", "Зарубежная поп-музыка", (428, 429, 1362, 1885, 1444)),
    ("russian-pop", "Русская поп-музыка", (424, 425, 1361, 239)),
    ("soviet", "Советская эстрада и ретро", (1635, 1634, 2401)),
    ("italian-pop", "Итальянская эстрада", (735, 1753)),
    ("latin", "Латиноамериканская музыка", (2232, 714)),
    ("asian-pop", "K-pop и J-pop", (1331, 1330)),
    ("chanson-foreign", "Французский и зарубежный шансон", (1219, 1452)),
    ("easy-listening", "Easy Listening и инструментальная эстрада", (2275, 2270, 450)),
    ("kids", "Детские песни", (1351,)),
    ("eurodance", "Евроданс", (2503, 2502, 2504)),
    ("disco", "Диско и итало-диско", (2501, 2500, 2505)),
    # Rap, R'n'B, reggae
    ("russian-rap", "Русский рэп", (441, 1173, 1486)),
    ("rap", "Зарубежный рэп и хип-хоп", (446, 909, 1835)),
    ("rnb", "R'n'B, соул и фанк", (1172, 1665, 2283)),
    ("reggae", "Регги, ска и даб", (1764, 1767, 1769, 1765, 1771, 1770, 1768, 1774, 1772, 2233)),
    # Jazz and blues
    ("jazz", "Джаз", (2287, 2267, 2277, 2278, 2279, 2280, 2281, 2282, 2353, 2284, 2286, 2297, 2295, 2302, 2301)),
    ("vocal-jazz", "Вокальный джаз", (2285, 2303)),
    ("blues", "Блюз", (2293, 2292, 2290, 2289, 2288, 2296, 2298, 2345)),
    # Electronic
    ("psytrance", "Гоа и пситранс", (1844, 1822)),
    ("psychill", "Псичилл и эмбиент-даб", (1894, 1895)),
    ("trance", "Транс", (1818, 1819, 1847)),
    ("house", "Хаус", (1857, 1858, 840, 1860)),
    ("techno", "Техно", (1825, 1826, 1828)),
    ("hardstyle", "Хардкор и хардстайл", (1829, 1830, 1831)),
    ("drum-and-bass", "Драм-н-бейс", (1832, 1833)),
    ("breakbeat", "Брейкбит и дабстеп", (1836, 1837, 1839, 454)),
    ("electro", "Электро", (797, 1805)),
    ("idm", "IDM", (1840, 1841, 2229)),
    ("chillout", "Чиллаут и лаунж", (1861, 1862)),
    ("nu-jazz", "Ню-джаз и эйсид-джаз", (1947, 1946)),
    ("trip-hop", "Трип-хоп", (1945, 1944)),
    ("ambient", "Эмбиент и электроника", (1810, 1864, 1865, 1893, 1754)),
    ("experimental", "Экспериментальная электроника", (1869, 1873)),
    ("ebm", "EBM и дарк-электро", (1868, 1875)),
    ("synthpop", "Синти-поп и нью-вейв", (1880, 1881)),
    ("synthwave", "Синтвейв", (466, 465)),
    ("darkwave", "Дарквейв и неоклассика", (1866, 406)),
    # Classical, folk, the rest
    ("classical", "Классическая музыка", (560, 436, 794, 556, 2307, 557, 2310, 2308, 558, 793, 1395, 2309, 2311, 969, 1164, 1884, 1660)),
    ("modern-classical", "Современная академическая музыка", (1871, 1867)),
    ("folk", "Фолк и этническая музыка", (1130, 1131, 1132, 1133, 2084, 1128, 1129, 1856, 2430, 1283, 2085, 1282, 1284, 1285, 1138, 506)),
    ("country", "Кантри и блюграсс", (1136, 1137)),
    ("new-age", "Нью-эйдж и релакс", (1126, 1127, 2513, 855)),
    ("flamenco", "Фламенко и акустическая гитара", (1134, 1135)),
    ("soundtracks", "Саундтреки и мюзиклы", (691, 469, 786, 785, 1631, 1499, 715, 796, 880, 1397, 1625)),
    ("anime", "Музыка из аниме", (1388, 282)),
    ("game-music", "Музыка из игр и чиптюн", (784, 783, 2331, 2431, 1907)),
    ("chanson", "Шансон", (1220, 1221, 1334, 1217)),
    ("bard", "Авторская и военная песня", (1224, 1225, 1226, 1216, 1223)),
)

GENRE_BY_FORUM: dict[int, str] = {
    forum: slug for slug, _name, forums in GENRES for forum in forums
}
GENRE_NAMES: dict[str, str] = {slug: name for slug, name, _forums in GENRES}

# Section slug of the catalog → top of v2. The old GENRES are left alone: the genre screens and API
# are still on them (that is V5). The artist_genre builder reads only this.
CATALOG_TO_OUR: dict[str, str] = {
    "classic-rock": "rock",
    "prog-rock": "rock",
    "folk-rock": "rock",
    "pop-rock": "rock",
    "guitar-rock": "rock",
    "rockabilly": "rock",
    "asian-rock": "rock",
    "alternative": "alternative",
    "punk": "punk",
    "indie": "alternative",
    "post-punk": "punk",
    "post-rock": "rock",
    "metalcore": "metal",
    "gothic-rock": "rock",
    "experimental-rock": "rock",
    "industrial": "electronic",
    "russian-rock": "rock",
    "russian-alternative": "alternative",
    "russian-metal": "metal",
    "heavy-metal": "metal",
    "thrash-metal": "metal",
    "death-metal": "metal",
    "black-metal": "metal",
    "folk-metal": "metal",
    "gothic-metal": "metal",
    "stoner": "metal",
    "pop": "pop",
    "russian-pop": "pop",
    "soviet": "pop",
    "italian-pop": "pop",
    "latin": "latin",
    "asian-pop": "pop",
    # French chanson is not our "Chanson" (russian chanson), it is estrada/pop.
    "chanson-foreign": "pop",
    "easy-listening": "easy-listening",
    "kids": "kids",
    "eurodance": "dance",
    "disco": "dance",
    "russian-rap": "hip-hop",
    "rap": "hip-hop",
    "rnb": "rnb",
    "reggae": "reggae",
    "jazz": "jazz",
    "vocal-jazz": "jazz",
    "blues": "blues",
    "psytrance": "dance",
    "psychill": "electronic",
    "trance": "dance",
    "house": "dance",
    "techno": "dance",
    "hardstyle": "dance",
    "drum-and-bass": "dance",
    "breakbeat": "dance",
    "electro": "electronic",
    "idm": "electronic",
    "chillout": "electronic",
    "nu-jazz": "jazz",
    "trip-hop": "electronic",
    "ambient": "electronic",
    "experimental": "electronic",
    "ebm": "electronic",
    "synthpop": "pop",
    "synthwave": "electronic",
    "darkwave": "electronic",
    "classical": "classical",
    "modern-classical": "classical",
    "folk": "folk",
    "country": "country",
    "new-age": "easy-listening",
    "flamenco": "latin",
    "soundtracks": "soundtrack",
    "anime": "soundtrack",
    "game-music": "soundtrack",
    "chanson": "worldwide",
    "bard": "singer-songwriter",
}


def our_slug_for_forum(forum_id: int) -> str | None:
    slug = GENRE_BY_FORUM.get(forum_id)
    if slug is None:
        return None
    return CATALOG_TO_OUR.get(slug)
