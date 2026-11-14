import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../book_client.dart';
import '../book_playback.dart';
import '../book_progress.dart';
import '../book_search.dart';
import '../book_shelf.dart';
import '../l10n/l10n.dart';
import '../listening_languages.dart';
import 'book_page.dart';
import 'books_page.dart';
import 'parts.dart';

/// Audiobooks: shelf and search under a header with "back". Entry point — tile in "Browse".
class BooksScreen extends StatefulWidget {
  const BooksScreen({
    super.key,
    required this.services,
    this.onPlayBook,
    this.bookProgress,
    this.languages,
  });

  final Services services;
  final void Function(ShelfBook book)? onPlayBook;
  final BookProgressStore? bookProgress;
  final ListeningLanguages? languages;

  @override
  State<BooksScreen> createState() => _BooksScreenState();
}

class _BooksScreenState extends State<BooksScreen> {
  BookClient? _bookClient;
  BookShelfModel? _bookShelf;
  BookSearchModel? _bookSearch;

  BookClient get _client =>
      _bookClient ??= BookClient(widget.services.server.bookSend);

  BookShelfModel get _shelf => _bookShelf ??= BookShelfModel(_client);

  BookSearchModel get _search =>
      _bookSearch ??= BookSearchModel(_client, languages: widget.languages);

  @override
  void didUpdateWidget(BooksScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.services.server != widget.services.server) {
      _bookClient = null;
      _bookShelf?.dispose();
      _bookShelf = null;
      _bookSearch?.dispose();
      _bookSearch = null;
    }
  }

  @override
  void dispose() {
    _bookShelf?.dispose();
    _bookSearch?.dispose();
    super.dispose();
  }

  void _listenBook(ShelfBook book) {
    if (widget.onPlayBook != null) {
      widget.onPlayBook!(book);
    } else {
      widget.services.play(BookPlayback.tracksFor(book), 0);
    }
  }

  void _openBookPage(ShelfBook book) {
    final text = l10n(context);
    final progress = widget.bookProgress;
    unawaited(
      open(
        context,
        BookPage(
          info: BookPageInfo(
            title: book.title,
            author: book.author.isNotEmpty ? book.author : null,
            narrator: book.narrator.isNotEmpty ? book.narrator : null,
            language: '',
            year: book.year,
            parts: book.parts,
          ),
          mode: BookPageMode.onShelf,
          position: progress?.of(book.id),
          texts: _bookPageTexts(text),
          onListen: () => _listenBook(book),
          onRestart: () async {
            await progress?.restart(book.id);
            _listenBook(book);
          },
          onRemove: () async {
            await _shelf.remove(book.id);
            if (mounted) Navigator.pop(context);
          },
          onToShelf: () => Navigator.pop(context),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final text = l10n(context);
    return Scaffold(
      appBar: AppBar(title: Text(text.libraryBooks)),
      body: BooksPage(
        shelf: _shelf,
        search: _search,
        languages: widget.languages,
        texts: _booksPageTexts(text),
        onOpenBook: _openBookPage,
        onListen: _listenBook,
      ),
    );
  }
}

BooksPageTexts _booksPageTexts(AppLocalizations text) => BooksPageTexts(
  searchHint: text.booksSearchHint,
  shelfTitle: text.booksShelfTitle,
  emptyShelf: text.booksEmptyShelf,
  loadFailed: text.booksLoadFailed,
  retry: text.booksRetry,
  searching: text.booksSearching,
  searchFailed: text.booksSearchFailed,
  nothingFound: text.booksNothingFound,
  add: text.booksAdd,
  adding: text.booksAdding,
  onShelf: text.booksOnShelf,
  listen: text.booksListen,
  languages: text.booksLanguages,
  allLanguages: text.booksAllLanguages,
  noBooksInLanguages: text.booksNoInLanguages,
  searchAllLanguages: text.booksSearchAllLanguages,
  languageName: text.languageName,
  size: (bytes) => bookSizeText(bytes, text.localeName),
  failure: (f) => switch (f) {
    BookFailure.offline => text.booksFailureOffline,
    BookFailure.unavailable => text.booksFailureUnavailable,
    BookFailure.searchUnavailable => text.booksFailureSearchUnavailable,
    BookFailure.expired => text.booksFailureExpired,
    BookFailure.noSpace => text.booksFailureNoSpace,
    BookFailure.limit => text.booksFailureLimit,
    BookFailure.notABook => text.booksFailureNotABook,
    BookFailure.notOnShelf => text.booksFailureNotOnShelf,
    BookFailure.signedOut => text.booksFailureSignedOut,
    BookFailure.broken => text.booksFailureBroken,
  },
);

BookPageTexts _bookPageTexts(AppLocalizations text) => BookPageTexts(
  addToShelf: text.bookPageAddToShelf,
  addFailed: text.bookPageAddFailed,
  listen: text.bookPageListen,
  continueListening: text.bookPageContinue,
  restart: text.bookPageRestart,
  removeFromShelf: text.bookPageRemoveFromShelf,
  removeConfirm: text.bookPageRemoveConfirm,
  removeYes: text.bookPageRemoveYes,
  cancel: text.bookPageCancel,
  narrator: text.bookPageNarrator,
  language: text.bookPageLanguage,
  duration: text.bookPageDuration,
  parts: text.bookPageParts,
  year: text.bookPageYear,
  partsAfterAdding: text.bookPagePartsAfterAdding,
  partsCount: text.bookPagePartsCount,
  gone: text.bookPageGone,
  toMyShelf: text.bookPageToMyShelf,
);

/// Release size: megabytes up to a gigabyte, then gigabytes with one decimal (FT-864).
String bookSizeText(int bytes, String locale) {
  const mb = 1024 * 1024;
  final text = lookupAppLocalizations(
    Locale(locale.split(RegExp('[-_]')).first),
  );
  if (bytes < 1024 * mb) {
    return text.downloadsSizeMb('${(bytes / mb).round()}');
  }
  return text.memoryGigabytes(
    NumberFormat('0.0', locale).format(bytes / (1024 * mb)),
  );
}
