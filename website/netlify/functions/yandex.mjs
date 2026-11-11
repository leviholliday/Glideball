// Yandex Webmaster's site check. It wants this exact page, but Netlify's
// snippet injection adds scripts to every static HTML file, so the page is
// served from here, where nothing gets injected.

export const config = { path: "/yandex_a9b11caad943cc18.html" };

const PAGE = `<html>
    <head>
        <meta http-equiv="Content-Type" content="text/html; charset=UTF-8">
    </head>
    <body>Verification: a9b11caad943cc18</body>
</html>
`;

export default () => new Response(PAGE, { headers: { "content-type": "text/html; charset=UTF-8" } });
