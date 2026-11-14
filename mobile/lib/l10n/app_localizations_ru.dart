// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Russian (`ru`).
class AppLocalizationsRu extends AppLocalizations {
  AppLocalizationsRu([String locale = 'ru']) : super(locale);

  @override
  String get updateTitle => 'Доступно обновление';

  @override
  String updateVersion(String version) {
    return 'Версия $version';
  }

  @override
  String get updateInstall => 'Обновить';

  @override
  String get updateSkip => 'Пропустить эту версию';

  @override
  String updateDownloading(int percent) {
    return 'Скачивается… $percent %';
  }

  @override
  String get updateFailed => 'Не получилось обновить. Попробуйте ещё раз.';

  @override
  String get updateCheck => 'Проверить обновления';

  @override
  String get updateLatest => 'У вас последняя версия';

  @override
  String get loginTitle => 'Подключиться к Apertono';

  @override
  String ratingStar(int n) {
    return '$n из 5';
  }

  @override
  String get ratingDislike => 'Не нравится';

  @override
  String get ratingFailed => 'Не удалось сохранить оценку';

  @override
  String get playerRate => 'Оценить';

  @override
  String get playerLyrics => 'Текст';

  @override
  String get playerHeartHint =>
      'Удержите сердце, чтобы поставить оценку или отметить «Не нравится»';

  @override
  String get libraryRated => 'Оценённые';

  @override
  String ratedFrom(int n) {
    return 'От $n';
  }

  @override
  String get ratedEmpty => 'Оценённых песен пока нет';

  @override
  String get dislikedEmpty => 'Песен с пометкой «Не нравится» нет';

  @override
  String get ratedFailed => 'Не удалось загрузить список';

  @override
  String get ratedRetry => 'Повторить';

  @override
  String get loginSessionExpired => 'Сеанс истёк. Войдите снова.';

  @override
  String get loginServerAddress => 'Адрес сервера';

  @override
  String get loginAddressInvalid =>
      'Используйте HTTPS или HTTP-адрес домашней сети.';

  @override
  String get loginAddressUnsupported => 'Этот сервер не поддерживается';

  @override
  String get loginAddressUnreachable => 'Сервер по этому адресу не отвечает';

  @override
  String get loginAddressExample => 'например, 192.168.1.20:8088';

  @override
  String loginConnectVia(String address) {
    return 'Подключимся по адресу $address';
  }

  @override
  String get loginChangeServer => 'Другой сервер';

  @override
  String get loginNext => 'Далее';

  @override
  String get historyPauseTitle => 'Не записывать историю';

  @override
  String get historyPauseHint => 'На час, до завтра или бессрочно';

  @override
  String get historyPauseForHour => 'На час';

  @override
  String get historyPauseTillTomorrow => 'До завтра';

  @override
  String get historyPauseForever => 'Пока не включу снова';

  @override
  String get historyPauseForeverOn => 'Пока не включите снова';

  @override
  String historyPauseUntil(String time) {
    return 'До $time';
  }

  @override
  String get historyClear => 'Очистить историю';

  @override
  String get historyClearQuestion =>
      'Стереть всю историю прослушиваний? Вернуть её будет нельзя';

  @override
  String get historyClearConfirm => 'Стереть';

  @override
  String get historyClearCancel => 'Отмена';

  @override
  String get historyError =>
      'Не получилось. Проверьте сеть и попробуйте ещё раз';

  @override
  String get historyRemoved => 'Убрано из истории';

  @override
  String get historyRemove => 'Убрать из истории';

  @override
  String get historyUndo => 'Отменить';

  @override
  String get historyRemoveFailed => 'Не удалось убрать из истории';

  @override
  String get loginUsername => 'Имя пользователя';

  @override
  String get loginPassword => 'Пароль';

  @override
  String get prefetchTitle => 'Подгрузка следующей песни';

  @override
  String get prefetchAlways => 'Всегда';

  @override
  String get prefetchWifiOnly => 'Только Wi-Fi';

  @override
  String get prefetchNever => 'Никогда';

  @override
  String get prefetchNeverHint =>
      'Между песнями будет короткая пауза; экономит мобильный трафик';

  @override
  String get qualityTitle => 'Качество звука';

  @override
  String get qualityAuto => 'Авто';

  @override
  String get qualityAutoHint =>
      'По Wi-Fi — как есть, по мобильной сети — экономно';

  @override
  String get qualityEconomy => 'Всегда экономно';

  @override
  String get qualityEconomyHint => 'Меньше трафика на любой сети';

  @override
  String get qualityLossless => 'Только без потерь';

  @override
  String get qualityLosslessHint =>
      'FLAC, если он есть. Нет — сыграет то, что есть';

  @override
  String get loudnessTitle => 'Ровная громкость';

  @override
  String get loudnessHint => 'Громкие песни тише';

  @override
  String formatBadgeSpoken(String format) {
    return 'Формат: $format';
  }

  @override
  String get loginSignIn => 'Войти';

  @override
  String get loginErrorTimeout => 'Сервер не ответил вовремя';

  @override
  String get scrobbleWhy =>
      'Это необязательно. ListenBrainz и Last.fm — бесплатные сайты, которые ведут вашу статистику прослушиваний: что и сколько вы слушали. История остаётся у вас, даже если смените плеер. Подключите свой профиль — и приложение будет отправлять туда сыгранные песни.';

  @override
  String get scrobbleWhyLbOnly =>
      'Это необязательно. ListenBrainz — бесплатный сайт, который ведёт вашу статистику прослушиваний: что и сколько вы слушали. История остаётся у вас, даже если смените плеер. Подключите свой профиль — и приложение будет отправлять туда сыгранные песни.';

  @override
  String get scrobbleStateOff => 'Не подключено';

  @override
  String get scrobbleStateOn => 'Подключено';

  @override
  String get scrobbleStateBadToken =>
      'Сервис отклонил ключ. Подключите заново.';

  @override
  String get scrobbleStatePending => 'Ждёт вашего разрешения';

  @override
  String get scrobbleTokenLabel => 'Токен ListenBrainz';

  @override
  String get scrobbleLbWhere => 'Где взять токен';

  @override
  String get scrobbleConnect => 'Подключить';

  @override
  String get scrobbleDisconnect => 'Отключить';

  @override
  String get scrobbleLastfmAllow => 'Разрешить в Last.fm';

  @override
  String get scrobbleLastfmCheck => 'Проверить разрешение';

  @override
  String get scrobbleLastfmCancel => 'Отмена';

  @override
  String get scrobbleLoadFailed => 'Не удалось загрузить настройки';

  @override
  String get scrobbleRetry => 'Повторить';

  @override
  String get scrobbleErrorTokenShape =>
      'Это не похоже на токен: от 8 до 200 знаков без пробелов';

  @override
  String get scrobbleErrorSave => 'Не удалось сохранить. Попробуйте ещё раз.';

  @override
  String get scrobbleErrorLastfmStart =>
      'Last.fm не ответил. Попробуйте позже.';

  @override
  String get scrobbleErrorLastfmNotYet =>
      'Разрешение ещё не дано. Подтвердите на странице Last.fm и проверьте снова.';

  @override
  String get scrobbleErrorLastfmExpired =>
      'Время на разрешение вышло. Начните заново.';

  @override
  String get scrobbleHint =>
      'Прослушивания уходят только в подключённые сервисы. Пока включено «Не записывать», не уходит ничего.';

  @override
  String get loginErrorUnauthorized => 'Неверное имя или пароль';

  @override
  String get loginErrorBadCertificate => 'Недействительный сертификат сервера';

  @override
  String get loginErrorNetwork => 'Не удалось связаться с сервером';

  @override
  String get searchFailureNoAccess =>
      'Нет доступа: ключ сборки не подходит к серверу';

  @override
  String get searchFailureCatalogDown =>
      'Каталог сейчас не отвечает — попробуйте через минуту';

  @override
  String get searchFailureTooMany =>
      'Слишком много запросов — подождите и повторите';

  @override
  String get searchFailureNoAnswer => 'Сервер не ответил — проверьте связь';

  @override
  String get searchRecent => 'Недавние запросы';

  @override
  String get searchClear => 'Очистить';

  @override
  String get searchHeard => 'Недавно слушали';

  @override
  String get searchArtistLabel => 'Исполнитель';

  @override
  String get searchTracks => 'Треки';

  @override
  String get searchTitle => 'Поиск';

  @override
  String get searchHint => 'Исполнитель или песня';

  @override
  String get searchEmpty => 'Ничего не найдено';

  @override
  String get catalogKindLive => 'концерт';

  @override
  String get catalogKindCompilation => 'сборник';

  @override
  String get catalogKindSingle => 'сингл';

  @override
  String get catalogKindAlbum => 'альбом';

  @override
  String get catalogArtistOne => 'исполнитель';

  @override
  String get catalogArtistFew => 'исполнителя';

  @override
  String get catalogArtistMany => 'исполнителей';

  @override
  String get catalogNoGenres => 'Жанров пока нет';

  @override
  String get catalogBrowseTitle => 'Обзор';

  @override
  String get catalogAllGenres => 'Все жанры';

  @override
  String get catalogNoArtists => 'Исполнителей нет';

  @override
  String get catalogArtistNotFound => 'Исполнителя нет в каталоге';

  @override
  String get catalogAlbums => 'Альбомы';

  @override
  String get catalogEpAndSingles => 'EP и синглы';

  @override
  String get catalogLiveAndCompilations => 'Концерты и сборники';

  @override
  String get catalogListen => 'Слушать';

  @override
  String get catalogPopular => 'Популярное';

  @override
  String get catalogAllPopular => 'Все популярные';

  @override
  String get catalogAllAlbums => 'Все альбомы';

  @override
  String get catalogNoAlbums => 'Альбомов в каталоге нет';

  @override
  String get catalogSimilarArtists => 'Похожие исполнители';

  @override
  String get catalogAboutArtist => 'Об исполнителе';

  @override
  String get catalogFollowing => 'Вы следите';

  @override
  String get catalogFollow => 'Следить';

  @override
  String catalogPhotoCredit(String credit) {
    return 'фото: $credit';
  }

  @override
  String get catalogCollapse => 'Свернуть';

  @override
  String get catalogExpand => 'Раскрыть';

  @override
  String get catalogAlbumNotFound => 'Альбом не найден';

  @override
  String get catalogPlayAlbum => 'Играть альбом';

  @override
  String get catalogOtherEditions => 'Другие издания';

  @override
  String get catalogArtistNotFoundSongs => 'Исполнитель не найден';

  @override
  String get homeTitle => 'Главная';

  @override
  String get homeFavorites => 'Любимые песни';

  @override
  String get homeEmpty => 'Пока пусто';

  @override
  String get homeTrackOne => 'трек';

  @override
  String get homeTrackFew => 'трека';

  @override
  String get homeTrackMany => 'треков';

  @override
  String get homePlaylists => 'Плейлисты';

  @override
  String get homePlaylistOne => 'плейлист';

  @override
  String get homePlaylistFew => 'плейлиста';

  @override
  String get homePlaylistMany => 'плейлистов';

  @override
  String get partsNotFound => 'Не найдено';

  @override
  String get partsServerUnavailable => 'Сервер недоступен';

  @override
  String get partsTooMany => 'Слишком много запросов — подождите и повторите';

  @override
  String get partsNoAnswer => 'Сервер не ответил';

  @override
  String get partsNoAccess => 'Нет доступа: ключ сборки не подходит к серверу';

  @override
  String get partsConflict => 'Плейлист изменился — показан текущий';

  @override
  String get partsDownloads => 'Скачанное';

  @override
  String get partsRetry => 'Повторить';

  @override
  String get partsReportSend => 'Отправить отчёт';

  @override
  String get partsReportSent => 'Отчёт отправлен';

  @override
  String get partsReportOff => 'Отчёты выключены на сервере';

  @override
  String get partsReportFailed => 'Не удалось отправить';

  @override
  String get partsPause => 'Пауза';

  @override
  String get partsStopLoading => 'Остановить загрузку';

  @override
  String get partsPlay => 'Играть';

  @override
  String partsTrackMissing(String artist) {
    return '$artist · не нашлось';
  }

  @override
  String get partsMore => 'Ещё';

  @override
  String get partsPlayNext => 'Играть следующей';

  @override
  String get partsWillPlayNext => 'Сыграет следующей';

  @override
  String get partsQueueEnd => 'В конец очереди';

  @override
  String get partsOpenArtist => 'К исполнителю';

  @override
  String get partsOpenAlbum => 'К альбому';

  @override
  String get partsDownload => 'Скачать';

  @override
  String get partsDeleteFromPhone => 'Удалить с телефона';

  @override
  String get partsAddToPlaylist => 'Добавить в плейлист';

  @override
  String get partsRemoveFromPlaylist => 'Убрать из плейлиста';

  @override
  String get partsRemoveFromFavorites => 'Убрать из избранного';

  @override
  String get partsAddToFavorites => 'В избранное';

  @override
  String get partsPlaylistGone => 'Плейлиста больше нет';

  @override
  String get partsAlbumGone => 'Альбом не нашёлся';

  @override
  String get partsName => 'Название';

  @override
  String get partsCancel => 'Отмена';

  @override
  String partsDuplicatesTitle(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count песен уже есть в плейлисте',
      many: '$count песен уже есть в плейлисте',
      few: '$count песни уже есть в плейлисте',
      one: '$count песня уже есть в плейлисте',
    );
    return '$_temp0';
  }

  @override
  String get partsDuplicatesAddAll => 'Добавить все';

  @override
  String get partsDuplicatesOnlyNew => 'Только новые';

  @override
  String get partsSave => 'Сохранить';

  @override
  String get partsNewPlaylist => 'Новый плейлист';

  @override
  String partsAddedToPlaylist(String name) {
    return 'Добавлено в «$name»';
  }

  @override
  String get partsSongsGone => 'Песни или плейлиста больше нет';

  @override
  String get playerUnlike => 'Убрать из избранного';

  @override
  String get playerLike => 'В избранное';

  @override
  String get playerNoTrack => 'Нет трека';

  @override
  String get playerCollapse => 'Свернуть';

  @override
  String get playerMore => 'Ещё';

  @override
  String get playerMenuSong => 'Песня';

  @override
  String get playerMenuGo => 'Перейти';

  @override
  String get playerMenuHelp => 'Помощь';

  @override
  String get playerMenuSound => 'Звук';

  @override
  String get playerLosslessOnce => 'Эту песню без потерь';

  @override
  String get playerLosslessMissed => 'Без потерь для этой песни не нашлось';

  @override
  String get playerUndislike => 'Убрать «Не нравится»';

  @override
  String get playerToPodcast => 'К подкасту';

  @override
  String get playerAddToPlaylist => 'Добавить в плейлист';

  @override
  String get playerAddedToDownloads => 'Добавлено в «Загрузки»';

  @override
  String get playerDownload => 'В загрузки';

  @override
  String get playerShuffle => 'Перемешать';

  @override
  String get playerPrevious => 'Назад';

  @override
  String get playerNext => 'Вперёд';

  @override
  String get playerRepeatOff => 'Повтор выключен';

  @override
  String get playerRepeatAll => 'Повтор очереди';

  @override
  String get playerRepeatOne => 'Повтор песни';

  @override
  String get playerQueue => 'Очередь';

  @override
  String playerWaitSeconds(int seconds) {
    return ' · $seconds с';
  }

  @override
  String get miniSearchingSource => 'Ищем источник';

  @override
  String get miniPreparingAudio => 'Готовим звук';

  @override
  String get miniNoSource => 'Источник не нашёлся — повторить';

  @override
  String get miniUnknownTrack => 'Сервер не знает трек — найдите заново';

  @override
  String get miniNoAccess => 'Нет доступа — ключ сборки';

  @override
  String get miniNoAnswer => 'Сервер не ответил — повторить';

  @override
  String get miniDropped => 'Обрыв — повторить';

  @override
  String get miniFailed => 'Не удалось — повторить';

  @override
  String miniWaitSeconds(int seconds) {
    return ' · $seconds с';
  }

  @override
  String get libraryTitle => 'Моя музыка';

  @override
  String get libraryFavorites => 'Любимые песни';

  @override
  String libraryTracksCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count треков',
      many: '$count треков',
      few: '$count трека',
      one: '$count трек',
    );
    return '$_temp0';
  }

  @override
  String get libraryMediaSection => 'Медиатека';

  @override
  String get libraryRatingsSection => 'Мои оценки';

  @override
  String get libraryHistorySubtitle => 'Что слушали';

  @override
  String get libraryDownloadsSubtitle => 'Без интернета';

  @override
  String get libraryHistory => 'История';

  @override
  String get libraryPlaylists => 'Плейлисты';

  @override
  String libraryPlaylistsCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count плейлистов',
      many: '$count плейлистов',
      few: '$count плейлиста',
      one: '$count плейлист',
    );
    return '$_temp0';
  }

  @override
  String get libraryDownloads => 'Скачанное';

  @override
  String get libraryDevice => 'Музыка с телефона';

  @override
  String get libraryDeviceSubtitle => 'Из памяти';

  @override
  String get libraryDeviceTile => 'С телефона';

  @override
  String get libraryImport => 'Импорт';

  @override
  String get libraryImportSubtitle => 'Spotify, Apple Music, M3U, текст';

  @override
  String get libraryFavoritesEmpty => 'В избранном пока пусто';

  @override
  String get libraryHistoryEmpty => 'История пуста';

  @override
  String get libraryNewPlaylist => 'Новый плейлист';

  @override
  String get libraryPlaylistNotFound => 'Плейлиста больше нет';

  @override
  String get libraryRename => 'Переименовать';

  @override
  String libraryDeletePlaylistConfirm(String name) {
    return 'Удалить «$name»?';
  }

  @override
  String get libraryDeletePlaylistMessage =>
      'Песни останутся в каталоге и в избранном.';

  @override
  String get libraryCancel => 'Отмена';

  @override
  String get libraryDelete => 'Удалить';

  @override
  String get libraryDeletePlaylist => 'Удалить плейлист';

  @override
  String get libraryPlaylistEmpty =>
      'Пусто. Песни добавляются из поиска и альбомов';

  @override
  String get libraryPlayPlaylist => 'Играть плейлист';

  @override
  String memoryGigabytes(String gb) {
    return '$gb ГБ';
  }

  @override
  String get memoryDeleteAllTitle => 'Удалить все загрузки?';

  @override
  String get memoryDeleteAllMessage =>
      'Все скачанные песни будут удалены с телефона.';

  @override
  String get memoryCancel => 'Отмена';

  @override
  String get memoryDelete => 'Удалить';

  @override
  String get memoryTitle => 'Память';

  @override
  String memoryLegendDownloaded(String size) {
    return 'Скачанное · $size';
  }

  @override
  String memoryLegendReserve(String size) {
    return 'Запас · $size';
  }

  @override
  String memoryLegendFree(String size) {
    return 'Свободно · $size';
  }

  @override
  String get memoryReserveTitle => 'Запас прослушанного';

  @override
  String get memoryReserveOff => 'Выключен';

  @override
  String get memoryClearReserve => 'Очистить запас';

  @override
  String get memoryDeleteAll => 'Удалить все загрузки';

  @override
  String get navHome => 'Главная';

  @override
  String get navBrowse => 'Обзор';

  @override
  String get navNews => 'Новости';

  @override
  String get navSearch => 'Поиск';

  @override
  String get navLibrary => 'Моя музыка';

  @override
  String get newsTitle => 'Новости';

  @override
  String get newsConsentDescription =>
      'Новости приходят с этого сервера — от выбранных им источников. Чтобы собрать ленту, сервер сам ходит в интернет к ним. Телефон за новостями наружу не ходит.';

  @override
  String get newsConsentGotIt => 'Понятно';

  @override
  String get newsUnavailable => 'Новости недоступны';

  @override
  String get newsServerDisabled => 'Новости: выключено на этом сервере';

  @override
  String get newsReadFull => 'Читать полностью';

  @override
  String get newsSource => 'Источник';

  @override
  String get newsPlay => 'Слушать';

  @override
  String get newsEmpty => 'Пока новостей нет';

  @override
  String get newsSuggestionsTitle => 'Ты часто слушаешь';

  @override
  String get newsFollowAll => 'Следить за всеми';

  @override
  String get newsChannels => 'Каналы';

  @override
  String get channelsTitle => 'Каналы';

  @override
  String get channelsUnavailable => 'Каналы недоступны';

  @override
  String get channelsAddErrorNotPublic =>
      'Это внутренний адрес — канал добавить нельзя';

  @override
  String get channelsAddErrorTooMany => 'Достигнут лимит каналов';

  @override
  String get channelsAddErrorNotFeed => 'По этой ссылке не нашлось новостей';

  @override
  String get channelsAddErrorFailed => 'Сервер не ответил';

  @override
  String get channelsCuratedHeading => 'Готовый список';

  @override
  String get channelsOwnHeading => 'Мои каналы';

  @override
  String get channelsOwnEmpty => 'Пока пусто';

  @override
  String get channelsAddHeading => 'Добавить по ссылке';

  @override
  String get channelsAddLinkHint => 'Ссылка: @канал, t.me/… или адрес сайта';

  @override
  String get channelsAddButton => 'Добавить';

  @override
  String get channelsPopularHeading => 'Популярное на этом сервере';

  @override
  String get channelsPopularEmpty =>
      'Появятся каналы, которые добавили минимум три человека';

  @override
  String channelsPopularAdded(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count человек добавили',
      few: '$count человека добавили',
      one: '$count человек добавил',
    );
    return '$_temp0';
  }

  @override
  String get downloadsTitle => 'Загрузки';

  @override
  String downloadsProgress(int done, int total) {
    return 'Скачано $done из $total';
  }

  @override
  String downloadsFree(int size) {
    return 'Свободно $size ГБ';
  }

  @override
  String get downloadsHoldMetered =>
      'Пауза: скачивание по мобильной сети выключено';

  @override
  String get downloadsHoldNoRoom =>
      'Пауза: недостаточно свободного места на телефоне';

  @override
  String get downloadsAllowMobile => 'Качать по мобильной сети';

  @override
  String downloadsMemoryOf(String used, String total) {
    return 'Память · $used из $total';
  }

  @override
  String downloadsMemory(String used) {
    return 'Память · $used';
  }

  @override
  String get downloadsEpisodes => 'Выпуски подкастов';

  @override
  String get downloadsEmpty => 'Загрузок пока нет';

  @override
  String downloadsSizeMb(String size) {
    return '$size МБ';
  }

  @override
  String get downloadsRemove => 'Удалить';

  @override
  String get downloadsDownloadAll => 'Скачать все';

  @override
  String downloadsDownloading(int done, int total) {
    return 'Скачивается $done из $total';
  }

  @override
  String get downloadsOnPhone => 'Скачано на телефон';

  @override
  String downloadsOnPhoneDetail(String songs, int size) {
    return 'На телефоне: $songs · $size МБ';
  }

  @override
  String downloadsSongs(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count песен',
      many: '$count песен',
      few: '$count песни',
      one: '$count песня',
    );
    return '$_temp0';
  }

  @override
  String get downloadsRemoveFromPhone => 'Удалить с телефона';

  @override
  String downloadsNotificationProgress(String numFinished, String numTotal) {
    return 'Скачивается $numFinished из $numTotal';
  }

  @override
  String get downloadsNotificationComplete => 'Загрузка завершена';

  @override
  String get storageTitle => 'Место для музыки';

  @override
  String get storageDescription =>
      'Прослушанное остаётся на телефоне и не тратит интернет при повторе. 0 — не хранить; размер меняется в «Загрузках».';

  @override
  String get storageNoRoom =>
      'Свободного места почти нет — запас прослушанного выключен.';

  @override
  String storageValue(int count) {
    return '$count ГБ';
  }

  @override
  String get storageNext => 'Дальше';

  @override
  String storageHintFits(int flac, int opus) {
    return '≈ $flac песен FLAC / $opus Opus';
  }

  @override
  String get storageHintNothing => 'Не поместится ни одной песни';

  @override
  String get importFileTooLarge =>
      'Файл больше 10 МиБ. Выберите файл поменьше.';

  @override
  String get importChooseTrack => 'Выберите песню';

  @override
  String get importNone => 'Ни одна';

  @override
  String get importCancel => 'Отмена';

  @override
  String get importDescription =>
      'Перенесите свою музыку: Spotify — CSV или ZIP из Exportify; Apple Music — XML медиатеки; M3U/M3U8 или строки «исполнитель — песня». Яндекс — через TuneMyMusic в CSV.';

  @override
  String get importPickFile => 'Выбрать файл';

  @override
  String get importPasteText => 'Вставить текст';

  @override
  String get importTextHint => 'Исполнитель — песня, по одной на строку';

  @override
  String get importSend => 'Отправить';

  @override
  String get importSaveAll => 'Сохранить все';

  @override
  String importListFound(int found, int total) {
    return 'нашлось $found из $total';
  }

  @override
  String get importSaved => 'Сохранено';

  @override
  String get importNotFound => 'Не нашлось';

  @override
  String get importSelected => 'Выбрано';

  @override
  String get importDoubtful => 'Сомнительно';

  @override
  String get importFound => 'Нашлось';

  @override
  String importSummary(int found, int total, int doubtful, int missing) {
    return 'Нашлось $found из $total · сомнительно $doubtful · не нашлось $missing';
  }

  @override
  String get importToFavorites => 'В Любимые песни';

  @override
  String get importSave => 'Сохранить';

  @override
  String get importDoubtfulHint =>
      'Проверять сомнительные не обязательно. Ненайденные останутся бледными строками в плейлисте; в Любимые попадёт только найденное.';

  @override
  String get importTitle => 'Импорт';

  @override
  String get accountTitle => 'Аккаунт';

  @override
  String get accountAutoReports => 'Присылать отчёты автоматически';

  @override
  String get accountNews => 'Новости';

  @override
  String get accountScrobble => 'ListenBrainz и Last.fm';

  @override
  String get accountLogout => 'Выйти';

  @override
  String get accountSwitchServer => 'Сменить сервер';

  @override
  String get accountLogoutConfirm => 'Выйти из аккаунта?';

  @override
  String get accountSwitchServerConfirm => 'Сменить сервер?';

  @override
  String get accountAutoReportsConfirm => 'Присылать отчёты автоматически?';

  @override
  String get accountAutoReportsDescription =>
      'Когда в приложении случится сбой, оно само пришлёт на ваш сервер короткий отчёт: что сломалось, на каком экране и в каком месте кода. Без названий песен, поисковых запросов и адреса телефона.';

  @override
  String get accountCancel => 'Отмена';

  @override
  String get accountSendReports => 'Присылать';

  @override
  String get accountLeaveWarning =>
      'Чтобы вернуться, понадобится снова ввести пароль.';

  @override
  String get appPlayNext => 'Будет следующей';

  @override
  String get appEnqueued => 'Добавлено в очередь';

  @override
  String get appPlaybackChannel => 'Воспроизведение';

  @override
  String get sleepTimerTitle => 'Таймер сна';

  @override
  String get sleepTimer15Min => '15 мин';

  @override
  String get sleepTimer30Min => '30 мин';

  @override
  String get sleepTimer45Min => '45 мин';

  @override
  String get sleepTimer60Min => '1 час';

  @override
  String get sleepTimerEndOfSong => 'До конца песни';

  @override
  String sleepTimerMinLeft(int n) {
    String _temp0 = intl.Intl.pluralLogic(
      n,
      locale: localeName,
      other: 'Осталось $n мин',
      many: 'Осталось $n мин',
      few: 'Осталось $n мин',
      one: 'Осталась $n мин',
    );
    return '$_temp0';
  }

  @override
  String get sleepTimerTurnOff => 'Выключить';

  @override
  String get equalizerTitle => 'Эквалайзер';

  @override
  String get equalizerFlat => 'Ровно';

  @override
  String get equalizerBass => 'Басы';

  @override
  String get equalizerTreble => 'Высокие';

  @override
  String get equalizerVocal => 'Голос';

  @override
  String get equalizerWaiting => 'Эквалайзер настроится с первой песней';

  @override
  String get equalizerMissing => 'На этом телефоне эквалайзера нет';

  @override
  String equalizerHz(String value) {
    return '$value Гц';
  }

  @override
  String equalizerKhz(String value) {
    return '$value кГц';
  }

  @override
  String get lyricsNone => 'Текста этой песни пока нет';

  @override
  String get aboutTitle => 'О приложении';

  @override
  String get aboutCredits =>
      'Спасибо проектам, на которых держится приложение:\n\n• Тексты песен — LRCLIB\n• Каталог музыки — MusicBrainz\n• Обложки альбомов — Cover Art Archive\n• Фото исполнителей — Wikimedia Commons, с автором и лицензией под каждым фото';

  @override
  String get aboutLicenses => 'Лицензии';

  @override
  String get aboutClose => 'Закрыть';

  @override
  String get lyricsCredit => 'Текст: LRCLIB';

  @override
  String get lyricsInstrumental => 'Без слов';

  @override
  String get problemTitle => 'Сообщить о проблеме';

  @override
  String get problemReasonWrongTrack => 'Играет не та песня';

  @override
  String get problemReasonNoPlay => 'Не играет';

  @override
  String get problemReasonBadSound => 'Плохой звук';

  @override
  String get problemReasonCover => 'Не та обложка или её нет';

  @override
  String get problemReasonWrongName => 'Ошибка в названии или имени';

  @override
  String get problemReasonOther => 'Другое';

  @override
  String get problemTextHint => 'Пара слов, если хотите';

  @override
  String get problemSend => 'Отправить';

  @override
  String get problemSent => 'Спасибо, отчёт отправлен';

  @override
  String get problemTooMany => 'Слишком много отчётов. Попробуйте через час.';

  @override
  String get problemFailed => 'Не получилось отправить. Попробуйте ещё раз.';

  @override
  String get deviceTabSongs => 'Песни';

  @override
  String get deviceTabAlbums => 'Альбомы';

  @override
  String get deviceTabArtists => 'Исполнители';

  @override
  String get deviceTabFolders => 'Папки';

  @override
  String get deviceNoAccess =>
      'Чтобы показать музыку с телефона, приложению нужно разрешение.';

  @override
  String get deviceAllow => 'Разрешить';

  @override
  String get deviceDeniedForever =>
      'Доступ к музыке запрещён. Разрешить его можно в настройках телефона.';

  @override
  String get deviceOpenSettings => 'Открыть настройки';

  @override
  String get deviceEmpty => 'На телефоне музыки не нашлось';

  @override
  String get deviceFailed => 'Не удалось прочитать музыку с телефона';

  @override
  String get deviceRefresh => 'Обновить';

  @override
  String get deviceRefreshFailed => 'Не удалось обновить список';

  @override
  String get deviceUntitled => 'Без названия';

  @override
  String get deviceBack => 'Назад к списку';

  @override
  String get deviceTabEmpty => 'Здесь пока пусто';

  @override
  String deviceSongCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count песни',
      many: '$count песен',
      few: '$count песни',
      one: '$count песня',
    );
    return '$_temp0';
  }

  @override
  String get podcastsTitle => 'Подкасты';

  @override
  String get browseBooks => 'Аудиокниги';

  @override
  String get browseNotSetUp => 'Не настроено на сервере';

  @override
  String get audiobooksTitle => 'Аудиокниги';

  @override
  String get podcastsSearchHint => 'Найти подкаст';

  @override
  String get podcastsLanguages => 'Языки';

  @override
  String get podcastsContinue => 'Продолжить';

  @override
  String get podcastsNewEpisodes => 'Новые выпуски';

  @override
  String get podcastsSubscriptions => 'Подписки';

  @override
  String get podcastsPopular => 'Популярное';

  @override
  String get podcastsCategories => 'Категории';

  @override
  String get podcastsSubscribe => 'Подписаться';

  @override
  String get podcastsSubscribed => 'Подписан';

  @override
  String get podcastsSubscribeFailed =>
      'Не получилось подписаться. Попробуйте ещё раз.';

  @override
  String get podcastsSearchFailed => 'Поиск не удался. Проверьте связь.';

  @override
  String get podcastsNothingFound => 'Ничего не нашлось';

  @override
  String get podcastsSearchAllLanguages => 'Искать на всех языках';

  @override
  String get podcastsLoadFailed => 'Не удалось загрузить подкасты';

  @override
  String get podcastsRetry => 'Повторить';

  @override
  String get podcastsEmpty => 'Здесь пока пусто';

  @override
  String get podcastsAllLanguages => 'Все языки';

  @override
  String get podcastAbout => 'О подкасте';

  @override
  String get podcastEpisodes => 'Выпуски';

  @override
  String get podcastNewestFirst => 'Сначала новые';

  @override
  String get podcastOldestFirst => 'Сначала старые';

  @override
  String get podcastNoEpisodes => 'Выпусков пока нет';

  @override
  String get podcastUntitled => 'Выпуск без названия';

  @override
  String get podcastDownload => 'Скачать';

  @override
  String get podcastDownloading => 'Скачивается';

  @override
  String get podcastOnPhone => 'На телефоне';

  @override
  String get podcastDownloadFailed => 'Не удалось скачать';

  @override
  String get podcastNoRoom => 'На телефоне не хватает места';

  @override
  String get podcastMetered => 'Скачивание по мобильной сети выключено';

  @override
  String get podcastPlay => 'Слушать';

  @override
  String get podcastEpisodesFailed => 'Не удалось загрузить выпуски';

  @override
  String podcastHoursMinutes(int hours, int minutes) {
    return '$hours ч $minutes мин';
  }

  @override
  String podcastMinutes(int minutes) {
    return '$minutes мин';
  }

  @override
  String get playerSkipBack => 'Назад на 15 секунд';

  @override
  String get playerSkipForward => 'Вперёд на 30 секунд';

  @override
  String get playerSpeed => 'Скорость';

  @override
  String get knownAsHeading => 'Другие написания';

  @override
  String knownAsSpoken(String name) {
    return 'Также известен как $name';
  }

  @override
  String get crashTitle => 'В прошлый раз приложение закрылось с ошибкой';

  @override
  String get crashBody =>
      'Отправить отчёт? В нём только места в коде: ни песен, ни запросов, ни адресов.';

  @override
  String get crashSend => 'Отправить отчёт';

  @override
  String get crashSkip => 'Не сейчас';

  @override
  String get crashNever => 'Больше не спрашивать';

  @override
  String get crashSent => 'Отчёт отправлен';

  @override
  String get crashNotSent => 'Отчёт не отправлен';

  @override
  String get spokenSpeed => 'Скорость';

  @override
  String get spokenDownload => 'Скачать';

  @override
  String get spokenDownloaded => 'Скачано';

  @override
  String get spokenSleep => 'Таймер сна';

  @override
  String get spokenQueue => 'Очередь';

  @override
  String get spokenParts => 'Части';

  @override
  String get spokenRemaining => 'Осталось';

  @override
  String spokenRemainingMinutes(int m) {
    return '$m мин';
  }

  @override
  String spokenRemainingHoursMinutes(int h, int m) {
    return '$h ч $m мин';
  }

  @override
  String get libraryBooks => 'Книги';

  @override
  String get booksSearchHint => 'Название или автор';

  @override
  String get booksShelfTitle => 'Моя полка';

  @override
  String get booksEmptyShelf =>
      'На полке пока пусто.\nНайдите книгу в поиске выше и нажмите «На полку».';

  @override
  String get booksLoadFailed => 'Полка не загрузилась';

  @override
  String get booksRetry => 'Повторить';

  @override
  String get booksSearching => 'Ищу';

  @override
  String get booksSearchFailed => 'Поиск не удался';

  @override
  String get booksNothingFound => 'Ничего не нашлось';

  @override
  String get booksLanguages => 'Языки';

  @override
  String get booksAllLanguages => 'Все языки';

  @override
  String get booksNoInLanguages => 'Нет книг на выбранных языках';

  @override
  String get booksSearchAllLanguages => 'Искать на всех языках';

  @override
  String get booksAdd => 'На полку';

  @override
  String get booksAdding => 'Ставлю…';

  @override
  String get booksOnShelf => 'На полке';

  @override
  String get booksListen => 'Слушать';

  @override
  String get booksFailureOffline => 'Нет связи';

  @override
  String get booksFailureUnavailable => 'Сервис недоступен';

  @override
  String get booksFailureSearchUnavailable => 'Поиск недоступен';

  @override
  String get booksFailureExpired => 'Ссылка устарела';

  @override
  String get booksFailureNoSpace => 'Не хватает места';

  @override
  String get booksFailureLimit => 'Превышен лимит на полке';

  @override
  String get booksFailureNotABook => 'Это не аудиокнига';

  @override
  String get booksFailureNotOnShelf => 'Книга не на полке';

  @override
  String get booksFailureSignedOut => 'Требуется вход';

  @override
  String get booksFailureBroken => 'Ошибка данных';

  @override
  String get bookPageAddToShelf => 'Добавить на полку';

  @override
  String get bookPageAddFailed => 'Не удалось добавить';

  @override
  String get bookPageListen => 'Слушать';

  @override
  String get bookPageContinue => 'Продолжить';

  @override
  String get bookPageRestart => 'Начать заново';

  @override
  String get bookPageRemoveFromShelf => 'Убрать с полки';

  @override
  String get bookPageRemoveConfirm => 'Убрать книгу с полки?';

  @override
  String get bookPageRemoveYes => 'Убрать';

  @override
  String get bookPageCancel => 'Отмена';

  @override
  String get bookPageNarrator => 'Чтец';

  @override
  String get bookPageLanguage => 'Язык';

  @override
  String get bookPageDuration => 'Длительность';

  @override
  String get bookPageParts => 'Части';

  @override
  String get bookPageYear => 'Год записи';

  @override
  String get bookPagePartsAfterAdding => 'после добавления';

  @override
  String bookPagePartsCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count части',
      many: '$count частей',
      few: '$count части',
      one: '$count часть',
    );
    return '$_temp0';
  }

  @override
  String get bookPageGone => 'Книгу убрали с полки на другом телефоне';

  @override
  String get bookPageToMyShelf => 'К моей полке';

  @override
  String get foreignTabLibrary => 'Медиатека';

  @override
  String get foreignTabFavorites => 'Избранное';

  @override
  String get foreignLeave => 'Выйти';

  @override
  String get foreignRetry => 'Повторить';

  @override
  String get foreignLoadFailed => 'Не удалось загрузить — проверьте связь';

  @override
  String get foreignLikeFailed => 'Не удалось изменить избранное';

  @override
  String get foreignAlbums => 'Альбомы';

  @override
  String get foreignArtists => 'Исполнители';

  @override
  String get foreignFavoritesEmpty => 'Избранных песен пока нет';

  @override
  String get foreignLike => 'В избранное';

  @override
  String get foreignUnlike => 'Убрать из избранного';

  @override
  String get foreignBack => 'Назад';

  @override
  String languageName(String code) {
    String _temp0 = intl.Intl.selectLogic(code, {
      'ru': 'Русский',
      'en': 'Английский',
      'uk': 'Украинский',
      'de': 'Немецкий',
      'fr': 'Французский',
      'es': 'Испанский',
      'it': 'Итальянский',
      'pl': 'Польский',
      'pt': 'Португальский',
      'tr': 'Турецкий',
      'be': 'Белорусский',
      'zh': 'Китайский',
      'ja': 'Японский',
      'ko': 'Корейский',
      'other': '',
    });
    return '$_temp0';
  }

  @override
  String get loginErrorBadCode =>
      'Код не подошёл: проверьте имя и код или попросите у администратора новый';

  @override
  String get loginErrorWeakPassword => 'Пароль — от 8 знаков';

  @override
  String get loginHaveCode => 'Первый вход по коду';

  @override
  String get loginHavePassword => 'У меня уже есть пароль';

  @override
  String get loginCode => 'Код от администратора';

  @override
  String get loginNewPassword => 'Придумайте пароль (от 8 знаков)';

  @override
  String get loginRepeatPassword => 'Повторите пароль';

  @override
  String get loginPasswordsDiffer => 'Пароли не совпадают';

  @override
  String get loginClaim => 'Сохранить пароль и войти';

  @override
  String get accountChangePassword => 'Сменить пароль';

  @override
  String get passwordOld => 'Текущий пароль';

  @override
  String get passwordChanged =>
      'Пароль сменён. На других устройствах вход закрыт';

  @override
  String get passwordWrongOld => 'Текущий пароль неверный';

  @override
  String get passwordFailed => 'Сервер не ответил. Попробуйте ещё раз';

  @override
  String get passwordSave => 'Сохранить';
}
