package cn.apt.rootaudio;

import java.io.StringReader;
import org.xmlpull.v1.XmlPullParser;
import org.xmlpull.v1.XmlPullParserFactory;

/** Read only the existing gate or one UUID-scoped upload revocation. No destinations/provider keys. */
final class RootUploadCredential {
    private RootUploadCredential() {}
    static String read(RootApp app) throws Exception {
        String selected = readValue(app,"growth.stepx.gate");
        if (selected == null) return null;
        selected = selected.trim();
        if (selected.length() < 12 || selected.length() > 512 || selected.contains("\r") || selected.contains("\n")) return null;
        return selected;
    }
    static boolean deleted(RootApp app, String matter) throws Exception {
        return readValue(app,"growth.root.capture.deleted." + RootUploadIdentity.uuid(matter)) != null;
    }
    private static String readValue(RootApp app, String key) throws Exception {
        String xml;
        try (PrivateDirectory prefs = new PrivateDirectory(app.data + "/shared_prefs", app.uid, false)) {
            xml = prefs.read("aiapp_store_" + RootApp.PACKAGE + ".xml", 262144, app.uid);
        }
        if (xml.contains("<!DOCTYPE") || xml.contains("<!ENTITY")) throw new SecurityException("XML declaration");
        XmlPullParserFactory factory = XmlPullParserFactory.newInstance(); factory.setNamespaceAware(false);
        XmlPullParser parser = factory.newPullParser(); parser.setInput(new StringReader(xml));
        String selected = null;
        for (int event = parser.getEventType(); event != XmlPullParser.END_DOCUMENT; event = parser.next()) {
            if (event == XmlPullParser.DOCDECL) throw new SecurityException("XML declaration");
            if (event == XmlPullParser.START_TAG && "string".equals(parser.getName())
                    && key.equals(parser.getAttributeValue(null, "name"))) {
                if (selected != null) throw new SecurityException("duplicate gate");
                selected = parser.nextText();
            }
        }
        if (selected == null) return null;
        if (selected.startsWith("\"")) {
            Object decoded = new org.json.JSONTokener(selected).nextValue();
            if (!(decoded instanceof String)) throw new SecurityException("gate type");
            selected = (String) decoded;
        }
        return selected;
    }
}
