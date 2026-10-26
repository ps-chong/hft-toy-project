// Boost configures BOOST_NO_EXCEPTIONS under -fno-exceptions and then
// requires the application to define boost::throw_exception. No Boost
// facility used by the firmware throws on its normal paths; if one ever does,
// the firmware must not continue in an unknown state, so this handler halts.

#include <cstdlib>
#include <exception>

#include <boost/assert/source_location.hpp>
#include <boost/throw_exception.hpp>

namespace boost {

[[noreturn]] auto throw_exception(std::exception const&) -> void { std::abort(); }

[[noreturn]] auto throw_exception(std::exception const&, boost::source_location const&)
    -> void {
  std::abort();
}

}  // namespace boost
