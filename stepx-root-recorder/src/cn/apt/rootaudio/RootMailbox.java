package cn.apt.rootaudio;

import java.io.StringReader;
import org.json.JSONObject;
import org.xmlpull.v1.XmlPullParser;
import org.xmlpull.v1.XmlPullParserFactory;

/** SharedPreferences is read-only here; only the single dedicated field is interpreted. */
final class RootMailbox implements AutoCloseable {
    static final String KEY = "growth.root.capture.command.v1";
    private final PrivateDirectory prefs;
    private final int uid;
    private final String key;
    RootMailbox(RootApp app) throws Exception { this(app, KEY); }
    RootMailbox(RootApp app, String key) throws Exception {
        if (!KEY.equals(key) && !"growth.neo.back.command.v1".equals(key)) throw new SecurityException("mailbox key");
        this.key = key; prefs = new PrivateDirectory(app.data + "/shared_prefs", app.uid, false); uid = app.uid;
    }
    JSONObject read() throws Exception {
        String xml = prefs.read("aiapp_store_" + RootApp.PACKAGE + ".xml", 262144, uid);
        if (xml.contains("<!DOCTYPE") || xml.contains("<!ENTITY")) throw new SecurityException("XML entities");
        XmlPullParserFactory factory = XmlPullParserFactory.newInstance(); factory.setNamespaceAware(false);
        XmlPullParser parser = factory.newPullParser(); parser.setInput(new StringReader(xml));
        String selected = null;
        for (int event = parser.getEventType(); event != XmlPullParser.END_DOCUMENT; event = parser.next()) {
            if (event == XmlPullParser.DOCDECL) throw new SecurityException("XML declaration");
            if (event == XmlPullParser.START_TAG && "string".equals(parser.getName()) && key.equals(parser.getAttributeValue(null, "name"))) {
                if (selected != null) throw new SecurityException("duplicate command");
                selected = parser.nextText();
            }
        }
        if (selected == null) return null;
        // Native SDK stores JSON-stringified data; unwrap one string layer only.
        if (selected.startsWith("\"")) selected = (String) new org.json.JSONTokener(selected).nextValue();
        if (selected.length() > 4096) throw new SecurityException("command length");
        return new JSONObject(selected);
    }
    static String uuid(JSONObject value, String key) throws Exception {
        String id = value.getString(key);
        if (!id.matches("[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")) throw new SecurityException("identity");
        return id;
    }
    @Override public void close() throws Exception { prefs.close(); }
}
