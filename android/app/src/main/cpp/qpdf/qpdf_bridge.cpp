#include <jni.h>

#include <exception>
#include <stdexcept>
#include <string>
#include <vector>

extern "C" int qpdfjob_run_from_argv(char const* const argv[]);

namespace {

std::string to_utf8(JNIEnv* env, jstring value) {
    if (value == nullptr) {
        throw std::invalid_argument("A PDF path is required.");
    }
    const char* chars = env->GetStringUTFChars(value, nullptr);
    if (chars == nullptr) {
        throw std::runtime_error("A PDF path could not be read.");
    }
    std::string result(chars);
    env->ReleaseStringUTFChars(value, chars);
    return result;
}

void throw_java(JNIEnv* env, const char* message) {
    jclass exception_class = env->FindClass("java/lang/IllegalStateException");
    if (exception_class != nullptr) {
        env->ThrowNew(exception_class, message);
    }
}

int run_qpdf(const std::vector<std::string>& arguments) {
    std::vector<const char*> argv;
    argv.reserve(arguments.size() + 1);
    for (const auto& argument : arguments) {
        argv.push_back(argument.c_str());
    }
    argv.push_back(nullptr);
    return qpdfjob_run_from_argv(argv.data());
}

}  // namespace

extern "C" JNIEXPORT jint JNICALL
Java_com_myphotw_scana_pdfeditor_QpdfNative_validateNative(
    JNIEnv* env,
    jobject,
    jstring input_path) {
    try {
        const std::string input = to_utf8(env, input_path);
        return run_qpdf({"qpdf", input, "--check"});
    } catch (const std::exception& error) {
        throw_java(env, error.what());
    } catch (...) {
        throw_java(env, "Unknown qpdf validation failure.");
    }
    return 2;
}

extern "C" JNIEXPORT jint JNICALL
Java_com_myphotw_scana_pdfeditor_QpdfNative_editNative(
    JNIEnv* env,
    jobject,
    jstring input_path,
    jstring output_path,
    jintArray page_numbers) {
    try {
        const std::string input = to_utf8(env, input_path);
        const std::string output = to_utf8(env, output_path);
        if (page_numbers == nullptr) {
            throw std::invalid_argument("A page order is required.");
        }
        const jsize count = env->GetArrayLength(page_numbers);
        if (count <= 0) {
            throw std::invalid_argument("At least one page is required.");
        }
        std::vector<jint> pages(static_cast<size_t>(count));
        env->GetIntArrayRegion(page_numbers, 0, count, pages.data());
        if (env->ExceptionCheck()) {
            return 2;
        }
        std::string range;
        for (jsize index = 0; index < count; ++index) {
            if (pages[static_cast<size_t>(index)] <= 0) {
                throw std::invalid_argument("Page numbers must be one-based.");
            }
            if (!range.empty()) {
                range.push_back(',');
            }
            range += std::to_string(pages[static_cast<size_t>(index)]);
        }
        return run_qpdf({
            "qpdf",
            input,
            output,
            "--pages",
            ".",
            range,
            "--",
        });
    } catch (const std::exception& error) {
        throw_java(env, error.what());
    } catch (...) {
        throw_java(env, "Unknown qpdf editing failure.");
    }
    return 2;
}
