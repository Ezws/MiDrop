package dev.midrop;

import android.net.Uri;

final class TextSharing {
    static Uri webLink(String text) {
        String value=text.trim();
        if (value.matches("(?s).*\\s.*")) return null;
        Uri uri=Uri.parse(value);
        String scheme=uri.getScheme();
        return ("https".equalsIgnoreCase(scheme) || "http".equalsIgnoreCase(scheme))
            && uri.getHost()!=null && !uri.getHost().isEmpty() ? uri : null;
    }
}
