---
name: web-ui-injection
description: >-
  Playbook for adding or altering Docmost web-UI filters and custom components
  by injecting CSS/JS (UserScripts.css / UserScripts.js) — not by forking
  Docmost. Covers how to find rebuild-stable selectors against the DEPLOYED
  Docmost build (CSS-module name prefixes, Mantine ids, ARIA, :has()), common
  gotchas (shared containers, virtualization, over-matching). Use whenever
  hiding/restyling parts of the Docmost web UI, adding custom web behavior, or
  editing Sources/DocmostCore/UserScripts.swift.
---

# Скилл: фильтры и кастомные компоненты в вебе Docmost

Приложение показывает веб-интерфейс Docmost в `WKWebView`. Чтобы прятать/менять
части этого UI или добавлять поведение — **инжектим CSS/JS, не форкаем Docmost**.

## Где точки входа

`Sources/DocmostCore/UserScripts.swift`:

- `css` — глобальный стиль (скрытие блоков, фильтры, правка отступов/раскладки).
  Применяется к живому DOM SPA автоматически — **предпочитай CSS**.
- `js` — глобальный скрипт (поведение и то, что CSS не выражает). Уже содержит
  паттерн «`MutationObserver` + `requestAnimationFrame`-sweep» для DOM, который
  рендерится по запросу (меню, поповеры). Матчь по тексту/`role`, не по хэшу.

Обе строки уходят в `WebTab.installUserScripts` (под гардом `!isEmpty`) →
`addUserScript` на `.atDocumentEnd`, main frame. CSS прогоняется через
`styleInjectionJS`, который JSON-кодирует строку — кавычки внутри селекторов
безопасны. После правок нужен ребилд: `make build` / `make run`.

## Золотое правило: целься в РАЗВЁРНУТУЮ сборку, не в GitHub `main`

У пользователя может крутиться версия Docmost старее `main` (например, дерево на
`react-arborist`, а не новый `DocTree`). Селекторы должны совпадать с тем, что
реально отдаётся. Как достать живой DOM/CSS:

```sh
# 1. URL сервера — из UserDefaults приложения
defaults read xyz.vvzvlad.docmost          # ключ "servers" (или plist в ~/Library/Preferences)
# 2. Найти бандлы ассетов (статика отдаётся без авторизации)
curl -s https://<server>/ | grep -oE '(href|src)="/assets/[^"]+\.(css|js)"'
# 3. Скачать index-*.css / index-*.js и грепать по ним
```

## Шпаргалка по стабильным селекторам

- **CSS-модули Vite сохраняют исходное имя класса префиксом**: `.menuItems` →
  `._menuItems_1k1tz_32`. Используй подстроку `[class*="_menuItems_"]` — устойчиво
  к пересборкам (меняется только хвостовой хэш). Проверь, что токен есть в
  задеплоенном CSS: `grep -oE '\._menuItems_[A-Za-z0-9]+' index.css`.
- **Один `.module.css` = один средний хэш** у всех его классов (напр. `_1k1tz`
  — это `space-sidebar.module.css`). Так подтверждаешь, что класс принадлежит
  нужному компоненту.
- **Mantine**: стабильные классы `mantine-*`; у `Tabs` id строятся как
  `{id}-tab-{value}` / `{id}-panel-{value}` → конкретную вкладку ловим
  `[id*="-tab-resolved"]`. Иконки Tabler — `tabler-icon-*` (зависит от версии,
  проверяй).
- **ARIA/роли — самые стабильные зацепки**: `[role="treeitem"]`, `aria-level`,
  `aria-label`, `role="tab"`.
- **`:has()` доступен** (WebKit на таргете macOS 14+). Целься в контейнер по его
  содержимому: скрыть секцию, только если она оборачивает нужный класс, или общую
  панель — только в одном из её режимов.
- **Каскад**: авторский `!important` перебивает инлайновые стили от React (напр.
  инлайновый `padding-left: level*24px` у `react-arborist`).

## Сверяйся с исходниками (для структуры и намерения)

GitHub `docmost/docmost`, `apps/client/src/...`:

```sh
gh api repos/docmost/docmost/contents/<path> --jq '.content' | base64 -d
```

Читай `.tsx` + `.module.css`, чтобы понять DOM и кто кого оборачивает — но имена
классов **всегда перепроверяй по задеплоенному бандлу** (версии расходятся).

## Грабли

- **Общие контейнеры**: правый Aside держит Comments / TOC / Details по `tab`.
  Скоупь селектор (напр. `:has([id*="-tab-resolved"])`), чтобы трогать только
  нужный режим, а не всю панель.
- **Виртуализация/SPA**: CSS применяется живьём — это плюс CSS над JS. Если без JS
  никак, иди по существующему sweep-паттерну в `js`.
- **Over-match у голых селекторов**: `[class*="_foo_"]` через запятую — это
  всегда активное правило, а не условный fallback. Скоупь к родителю
  (`[class*="_navbar_"] [class*="_foo_"]`), чтобы не задеть чужой одноимённый класс.
- **Тесты обязательны** для новой логики в `DocmostCore`: достаточно проверить,
  что `css`/`js` содержат ключевые селекторы (см. `UserScriptTests`).

## Рабочий пример

Все три текущих правила (скрытие меню сайдбара, скрытие панели комментариев,
уменьшение отступа дерева) — в константе `css` в `UserScripts.swift`. Это
готовый референс трёх приёмов: `:has()` по дочернему классу, скоуп общей панели
по id вкладки Mantine, переопределение инлайнового отступа по `aria-level`.
