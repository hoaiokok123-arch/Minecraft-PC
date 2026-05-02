package com.apple.eawt;

public class Application {
    public static Object sApplication;

    public static Application getApplication() {
        if (!(sApplication instanceof Application)) {
            sApplication = new Application();
        }
        return (Application)sApplication;
    }
}
